defmodule LiliumChat.UploadsTest do
  @moduledoc """
  Domain tests for `LiliumChat.Uploads` (issue #14): presign/finalize wire
  shapes, validation, S3 HEAD verification and `Idempotency-Key` dedup.

  The S3 HEAD transport is the fake (`LiliumChat.S3.TestTransport`) wired in
  `config/test.exs`; its behaviour is set per-test via `:s3_fake_head`.
  """

  use LiliumChat.DataCase, async: false

  alias LiliumChat.Errors.ApiError
  alias LiliumChat.Uploads

  @user "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  setup do
    on_exit(fn -> Application.delete_env(:lilium_chat, :s3_fake_head) end)
    :ok
  end

  defp body(overlays \\ %{}) do
    Map.merge(
      %{
        "filename" => "image.png",
        "mime_type" => "image/png",
        "size_bytes" => 12_345,
        "width" => 512,
        "height" => 512,
        "blurhash" => "LFE.~f_3%D%M01V@kWM{Rj%Mt7WBt7WB"
      },
      overlays
    )
  end

  defp fake_head(result) do
    Application.put_env(:lilium_chat, :s3_fake_head, result)
  end

  defp attachment_row(attachment_id) do
    case Repo.query(
           "SELECT status, owner_user_id, kind, mime_type, size_bytes, storage_key, url " <>
             "FROM chat_v2.attachments WHERE attachment_id = $1",
           [attachment_id],
           type: true
         ) do
      {:ok, %Postgrex.Result{columns: cols, rows: [row | _]}} ->
        Map.new(Enum.zip(cols, row))

      _ ->
        nil
    end
  end

  defp assert_api_error(code, fun) do
    try do
      fun.()
      flunk("expected #{code}")
    rescue
      e in ApiError -> assert e.code == code
    end
  end

  # ------------------------------------------------------------- presign

  test "presign creates a pending attachment and returns the §8.1 wire shape" do
    result = Uploads.presign(@user, "key-presign-1", body())

    assert result["upload_method"] == "PUT"

    assert result["upload_headers"] == %{
             "Content-Type" => "image/png",
             "Cache-Control" => "public, max-age=31536000, immutable"
           }

    # Contract §8.1: 5-min TTL, ISO second precision.
    assert result["expires_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/

    # C7: PUT URL strips the bucket prefix; the signed key stays under chat/.
    upload_url = result["upload_url"]
    assert upload_url =~ ~r|^https://[^/]+/chat/|
    refute upload_url =~ "lilium-chat-attachments"
    assert upload_url =~ "X-Amz-Signature="
    assert upload_url =~ "X-Amz-Expires=300"

    id = result["attachment_id"]
    assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    row = attachment_row(id)
    assert row["status"] == "pending"
    assert row["owner_user_id"] == @user
    assert row["kind"] == "image"
    assert row["mime_type"] == "image/png"
    assert row["size_bytes"] == 12_345
    assert row["storage_key"] == "chat/" <> id
    assert row["url"] =~ "s3.kuma.homes/chat/" <> id
  end

  test "presign replays the cached response for the same Idempotency-Key + body" do
    r1 = Uploads.presign(@user, "key-idem-1", body())
    r2 = Uploads.presign(@user, "key-idem-1", body())
    assert r2 == r1
  end

  test "presign raises IDEMPOTENCY_CONFLICT for the same key with a different body" do
    Uploads.presign(@user, "key-conflict", body())

    assert_api_error("IDEMPOTENCY_CONFLICT", fn ->
      Uploads.presign(@user, "key-conflict", body(%{"size_bytes" => 99_999}))
    end)
  end

  test "presign raises UNSUPPORTED_ATTACHMENT_TYPE for a disallowed mime_type" do
    assert_api_error("UNSUPPORTED_ATTACHMENT_TYPE", fn ->
      Uploads.presign(@user, "key-mime", body(%{"mime_type" => "image/tiff"}))
    end)
  end

  test "presign raises ATTACHMENT_TOO_LARGE above the 20 MiB cap" do
    assert_api_error("ATTACHMENT_TOO_LARGE", fn ->
      Uploads.presign(@user, "key-too-large", body(%{"size_bytes" => 21 * 1024 * 1024}))
    end)
  end

  test "presign raises INVALID_MESSAGE when size_bytes is missing" do
    assert_api_error("INVALID_MESSAGE", fn ->
      Uploads.presign(@user, "key-no-size", %{
        "filename" => "image.png",
        "mime_type" => "image/png"
      })
    end)
  end

  test "presign requires an Idempotency-Key" do
    assert_api_error("INVALID_MESSAGE", fn ->
      Uploads.presign(@user, "", body())
    end)
  end

  # ------------------------------------------------------------- finalize

  test "finalize verifies the object via HEAD and returns the §8.2 projection" do
    r = Uploads.presign(@user, "key-finalize-1", body())
    id = r["attachment_id"]
    fake_head({:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}})

    result = Uploads.finalize(@user, id, nil, "key-finalize-1")

    assert result["attachment"]["attachment_id"] == id
    assert result["attachment"]["kind"] == "image"
    assert result["attachment"]["filename"] == "image.png"
    assert result["attachment"]["mime_type"] == "image/png"
    assert result["attachment"]["size_bytes"] == 12_345
    assert result["attachment"]["width"] == 512
    assert result["attachment"]["height"] == 512
    assert result["attachment"]["blurhash"] == "LFE.~f_3%D%M01V@kWM{Rj%Mt7WBt7WB"
    assert result["attachment"]["url"] =~ "s3.kuma.homes/chat/" <> id
    assert attachment_row(id)["status"] == "finalized"
  end

  test "finalize projection coerces omitted width/height to 0 (contract 8.2)" do
    r =
      Uploads.presign(@user, "key-finalize-dims", %{
        "filename" => "image.png",
        "mime_type" => "image/png",
        "size_bytes" => 12_345
      })

    id = r["attachment_id"]
    fake_head({:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}})

    result = Uploads.finalize(@user, id, nil, "key-finalize-dims")
    assert result["attachment"]["width"] == 0
    assert result["attachment"]["height"] == 0
    assert result["attachment"]["blurhash"] == nil
  end

  test "finalize is idempotent (second call replays the projection)" do
    r = Uploads.presign(@user, "key-finalize-2", body())
    id = r["attachment_id"]
    fake_head({:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}})

    r1 = Uploads.finalize(@user, id, nil, "key-finalize-2")
    r2 = Uploads.finalize(@user, id, nil, "key-finalize-2")
    assert r1 == r2
  end

  test "finalize raises UNSUPPORTED_ATTACHMENT_TYPE when the object is missing (404 HEAD)" do
    r = Uploads.presign(@user, "key-finalize-3", body())
    fake_head({:ok, 404, %{}})

    assert_api_error("UNSUPPORTED_ATTACHMENT_TYPE", fn ->
      Uploads.finalize(@user, r["attachment_id"], nil, "key-finalize-3")
    end)
  end

  test "finalize raises UNSUPPORTED_ATTACHMENT_TYPE on Content-Length mismatch" do
    r = Uploads.presign(@user, "key-finalize-4", body())
    fake_head({:ok, 200, %{"content-type" => "image/png", "content-length" => "999"}})

    assert_api_error("UNSUPPORTED_ATTACHMENT_TYPE", fn ->
      Uploads.finalize(@user, r["attachment_id"], nil, "key-finalize-4")
    end)
  end

  test "finalize: cross-user attachment is NOT FOUND (old-Worker owner-scoped parity)" do
    # The old Worker stores pending attachments inside the OWNER'S UserDirectory
    # DO, so a foreign user's finalize is a plain "not found" (415) rather
    # than a FORBIDDEN — contract §8.2 is silent on the exact code. We mirror
    # the owner-scoped lookup (issue #27 conformance).
    r = Uploads.presign(@other, "key-finalize-5", body())
    fake_head({:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}})

    assert_api_error("UNSUPPORTED_ATTACHMENT_TYPE", fn ->
      Uploads.finalize(@user, r["attachment_id"], nil, "key-finalize-5")
    end)
  end

  test "finalize raises UNSUPPORTED_ATTACHMENT_TYPE for an unknown attachment_id" do
    fake_head({:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}})
    unknown = "99999999-9999-7999-8999-999999999999"

    assert_api_error("UNSUPPORTED_ATTACHMENT_TYPE", fn ->
      Uploads.finalize(@user, unknown, nil, "key-finalize-6")
    end)
  end
end
