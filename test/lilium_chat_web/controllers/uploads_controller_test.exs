defmodule LiliumChatWeb.UploadsControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the attachment upload routes
  (contract §8.1–§8.2, issue #14).

  Runs real conns through the ENTIRE endpoint pipeline (CORS → RequestId →
  router → AuthPlug → controller), so JWT auth, the error envelope, CORS and
  X-Request-Id are all exercised. The S3 HEAD transport is the fake wired in
  `config/test.exs`; `:s3_fake_head` is set per-test.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT

  @origin "https://lilium.kuma.homes"
  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @uid2 "7f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  setup do
    on_exit(fn -> Application.delete_env(:lilium_chat, :s3_fake_head) end)
    :ok
  end

  defp request(method, path, headers, body) do
    conn =
      case body do
        nil ->
          Plug.Test.conn(method, path) |> apply_headers(headers)

        json ->
          Plug.Test.conn(method, path, Jason.encode!(json))
          |> apply_headers([{"content-type", "application/json"} | headers])
      end

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp auth_headers(claims \\ %{}, opts \\ []) do
    [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @uid), opts)}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  defp presign_body do
    %{
      "filename" => "image.png",
      "mime_type" => "image/png",
      "size_bytes" => 12_345,
      "width" => 512,
      "height" => 512
    }
  end

  # ------------------------------------------------------------- presign

  test "presign: no auth → 401 UNAUTHORIZED" do
    conn =
      request(
        :post,
        "/api/chat/uploads/images/presign",
        [{"origin", @origin} | presign_headers()],
        presign_body()
      )

    assert conn.status == 401
    assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
  end

  test "presign: 200 with the §8.1 wire shape and X-Request-Id" do
    headers =
      [{"origin", @origin}, {"idempotency-key", "web-presign-1"} | auth_headers()]

    conn = request(:post, "/api/chat/uploads/images/presign", headers, presign_body())
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]
    assert hd(get_resp_header(conn, "x-request-id")) =~ ~r/^req_/

    json = body_json(conn)
    assert json["upload_method"] == "PUT"
    assert json["upload_headers"]["Content-Type"] == "image/png"
    assert json["upload_headers"]["Cache-Control"] == "public, max-age=31536000, immutable"
    assert json["upload_url"] =~ ~r|^https://[^/]+/chat/|
    refute json["upload_url"] =~ "lilium-chat-attachments"
    assert json["expires_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/

    # Idempotent replay (same key + body) returns the identical response.
    conn2 = request(:post, "/api/chat/uploads/images/presign", headers, presign_body())
    assert body_json(conn2) == json
  end

  test "presign: unsupported mime_type → 415 UNSUPPORTED_ATTACHMENT_TYPE" do
    headers = [{"origin", @origin}, {"idempotency-key", "web-mime"} | auth_headers()]
    body = Map.put(presign_body(), "mime_type", "image/tiff")
    conn = request(:post, "/api/chat/uploads/images/presign", headers, body)
    assert conn.status == 415
    assert body_json(conn)["error"]["code"] == "UNSUPPORTED_ATTACHMENT_TYPE"
  end

  test "presign: oversized file → 413 ATTACHMENT_TOO_LARGE" do
    headers = [{"origin", @origin}, {"idempotency-key", "web-size"} | auth_headers()]
    body = Map.put(presign_body(), "size_bytes", 21 * 1024 * 1024)
    conn = request(:post, "/api/chat/uploads/images/presign", headers, body)
    assert conn.status == 413
    assert body_json(conn)["error"]["code"] == "ATTACHMENT_TOO_LARGE"
  end

  # ------------------------------------------------------------- finalize

  test "finalize: 200 with the §8.2 projection after a matching HEAD" do
    id = presign_for(@uid)

    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}}
    )

    headers =
      [{"origin", @origin}, {"idempotency-key", "web-finalize-1"} | auth_headers()]

    conn =
      request(
        :post,
        "/api/chat/uploads/images/#{id}/finalize",
        headers,
        %{"etag" => "\"obj-etag\""}
      )

    assert conn.status == 200
    json = body_json(conn)
    assert json["attachment"]["attachment_id"] == id
    assert json["attachment"]["kind"] == "image"
    assert json["attachment"]["url"] =~ "s3.kuma.homes/chat/" <> id
  end

  test "finalize: object missing (404 HEAD) → 415 UNSUPPORTED_ATTACHMENT_TYPE" do
    id = presign_for(@uid)
    Application.put_env(:lilium_chat, :s3_fake_head, {:ok, 404, %{}})

    headers =
      [{"origin", @origin}, {"idempotency-key", "web-finalize-2"} | auth_headers()]

    conn =
      request(:post, "/api/chat/uploads/images/#{id}/finalize", headers, %{"etag" => nil})

    assert conn.status == 415
    assert body_json(conn)["error"]["code"] == "UNSUPPORTED_ATTACHMENT_TYPE"
  end

  test "finalize: attachment owned by another user → 403 FORBIDDEN" do
    id = presign_for(@uid2)

    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}}
    )

    headers = [
      {"origin", @origin},
      {"idempotency-key", "web-finalize-3"},
      {"authorization", "Bearer " <> sign(%{"sub" => @uid})}
    ]

    conn =
      request(:post, "/api/chat/uploads/images/#{id}/finalize", headers, %{"etag" => nil})

    assert conn.status == 403
    assert body_json(conn)["error"]["code"] == "FORBIDDEN"
  end

  # ------------------------------------------------------------- helpers

  defp presign_headers do
    []
  end

  # Mint a presigned attachment via the endpoint as `user` and return its id.
  defp presign_for(user) do
    headers =
      [
        {"origin", @origin},
        {"idempotency-key", "web-mint-" <> LiliumChat.Ids.uuidv7()}
      ] ++
        [{"authorization", "Bearer " <> sign(%{"sub" => user})}]

    conn = request(:post, "/api/chat/uploads/images/presign", headers, presign_body())
    body_json(conn)["attachment_id"]
  end
end
