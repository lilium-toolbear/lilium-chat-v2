defmodule LiliumChat.S3Test do
  @moduledoc """
  Unit tests for `LiliumChat.S3` (issue #14 / C7).

  The heart of the test: the SigV4 canonical request is asserted **exactly**
  (it encodes the "sign with bucket, return without bucket" invariant), and the
  signature is recomputed **independently** (raw `:crypto.mac` key derivation +
  final HMAC, a separate code path) to confirm the module's signature matches.
  """

  # async: false — the head_object tests share the `:s3_fake_head` config with
  # the other DB-backed S3 tests; keeping them in the serialized pool avoids a
  # race on that key.
  use ExUnit.Case, async: false

  alias LiliumChat.S3

  @now DateTime.new!(~D[2026-06-21], ~T[05:30:00])
  @amz_date "20260621T053000Z"
  @key "chat/00000000-0000-7000-8000-000000000501"
  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxPyH4"

  defp cfg do
    %S3.Config{
      access_key_id: @access_key,
      secret_access_key: @secret,
      region: "us-east-1",
      endpoint: "https://s3.kuma.homes",
      bucket: "lilium-chat-attachments",
      public_base: "https://s3.kuma.homes",
      ttl_seconds: 300,
      transport: LiliumChat.S3.TestTransport
    }
  end

  # The exact canonical request the signer must produce (C7: URI has the bucket).
  @expected_canonical """
  PUT
  /lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501
  X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260621%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20260621T053000Z&X-Amz-Expires=300
  Cache-Control:public, max-age=31536000, immutable
  Content-Type:image/png
  host:s3.kuma.homes

  Cache-Control;Content-Type;host
  UNSIGNED-PAYLOAD
  """

  # Independent reference signature for the vector above (AWS SigV4, computed
  # with the raw :crypto.mac chain — see `sigv4_ref/6`).
  test "canonical_request is exactly the bucket-including canonical URI + signed headers" do
    expected = @expected_canonical |> String.trim_trailing("\n")
    assert S3.canonical_request(cfg(), @key, "image/png", @now) == expected
  end

  test "presign_put signs WITH the bucket but returns the PUT URL WITHOUT it" do
    {upload_url, expires_at, upload_headers} =
      S3.presign_put(cfg(), @key, "image/png", @now)

    # Returned URL path strips the bucket prefix (the browser hits /{key}).
    uri = URI.parse(upload_url)
    assert uri.scheme == "https"
    assert uri.host == "s3.kuma.homes"
    assert uri.path == "/chat/00000000-0000-7000-8000-000000000501"
    refute uri.path =~ "lilium-chat-attachments"

    # Query carries the presign params (S3 re-canonicalizes; order is ours).
    assert query(uri) |> get("X-Amz-Expires") == "300"
    assert query(uri) |> get("X-Amz-Algorithm") == "AWS4-HMAC-SHA256"
    assert query(uri) |> get("X-Amz-Date") == @amz_date
    assert query(uri) |> get("X-Amz-SignedHeaders") == "Cache-Control;Content-Type;host"
    assert query(uri) |> get("X-Amz-Credential") =~ "AKIAIOSFODNN7EXAMPLE"
    assert query(uri) |> get("X-Amz-Credential") =~ "us-east-1/s3/aws4_request"

    # Signature matches an independent recomputation over the canonical request.
    canonical = @expected_canonical |> String.trim_trailing("\n")
    assert query(uri) |> get("X-Amz-Signature") == sigv4_ref(canonical: canonical)

    # TTL: 5 min from now, contract §8.1 format.
    assert expires_at == "2026-06-21T05:35:00Z"

    # Content-Type + Cache-Control are signed and returned for the browser.
    assert upload_headers == %{
             "Content-Type" => "image/png",
             "Cache-Control" => "public, max-age=31536000, immutable"
           }
  end

  test "presign_put honors a custom TTL" do
    cfg = %{cfg() | ttl_seconds: 60}
    {url, expires_at, _} = S3.presign_put(cfg, @key, "image/png", @now)
    assert query(URI.parse(url)) |> get("X-Amz-Expires") == "60"
    assert expires_at == "2026-06-21T05:31:00Z"
  end

  test "canonical URI is signed (bucket present) even though the returned URL strips it" do
    canonical = S3.canonical_request(cfg(), @key, "image/png", @now)
    # The signed canonical URI keeps the bucket (C7).
    assert canonical =~ "/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501\n"
    # ...but the browser URL does not (covered in the presign test above).
  end

  # ------------------------------------------------------------ URL helpers

  test "URL helpers (weed pathname / object / browser / public)" do
    assert S3.weed_pathname("lilium-chat-attachments", @key) ==
             "/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501"

    assert S3.object_url("https://s3.kuma.homes", "lilium-chat-attachments", @key) ==
             "https://s3.kuma.homes/lilium-chat-attachments/chat/00000000-0000-7000-8000-000000000501"

    signed =
      "https://s3.kuma.homes/lilium-chat-attachments/chat/abc?X-Amz-Signature=z"

    assert S3.browser_upload_url(signed, "chat/abc") ==
             "https://s3.kuma.homes/chat/abc?X-Amz-Signature=z"

    assert S3.public_object_url("https://s3.kuma.homes", "chat/abc") ==
             "https://s3.kuma.homes/chat/abc"
  end

  test "attachment_object_key embeds only the id under chat/ (contract §8.1)" do
    assert S3.attachment_object_key("00000000-0000-7000-8000-000000000501", "a.png", "image/png") ==
             "chat/00000000-0000-7000-8000-000000000501"
  end

  # ------------------------------------------------------------------- HEAD

  test "head_object ok on exact Content-Type + Content-Length match" do
    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200,
       %{
         "content-type" => "image/png",
         "content-length" => "12345"
       }}
    )

    result = S3.head_object(cfg(), @key, "image/png", 12345)
    assert result == %{ok: true, content_type: "image/png", content_length: 12345}
  end

  test "head_object not-ok when Content-Type mismatches" do
    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200, %{"content-type" => "image/jpeg", "content-length" => "12345"}}
    )

    result = S3.head_object(cfg(), @key, "image/png", 12345)
    assert result.ok == false
    assert result.content_type == "image/jpeg"
  end

  test "head_object not-ok when Content-Length mismatches" do
    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200, %{"content-type" => "image/png", "content-length" => "999"}}
    )

    result = S3.head_object(cfg(), @key, "image/png", 12345)
    assert result.ok == false
    assert result.content_length == 999
  end

  test "head_object not-ok on 404" do
    Application.put_env(:lilium_chat, :s3_fake_head, {:ok, 404, %{}})
    assert S3.head_object(cfg(), @key, "image/png", 12345).ok == false
  end

  test "head_object not-ok on transport error" do
    Application.put_env(:lilium_chat, :s3_fake_head, {:error, :econnrefused})
    assert S3.head_object(cfg(), @key, "image/png", 12345).ok == false
  end

  # ------------------------------------------------------------ helpers

  # Parse a URL's query string into a map (single-valued; sufficient here).
  defp query(%URI{query: nil}), do: %{}

  defp query(%URI{query: q}) do
    q
    |> String.split("&")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k] -> Map.put(acc, URI.decode(k), "")
        [k, v] -> Map.put(acc, URI.decode(k), URI.decode(v))
      end
    end)
  end

  defp get(map, key), do: Map.get(map, key)

  # Independent SigV4 reference signature (separate code path from the module):
  # derives the signing key and signs the given canonical request.
  defp sigv4_ref(canonical: canonical) do
    date_stamp = "20260621"
    region = "us-east-1"

    k_date = :crypto.mac(:hmac, :sha256, "AWS4" <> @secret, date_stamp)
    k_region = :crypto.mac(:hmac, :sha256, k_date, region)
    k_service = :crypto.mac(:hmac, :sha256, k_region, "s3")
    k_signing = :crypto.mac(:hmac, :sha256, k_service, "aws4_request")

    canonical_hash = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)

    string_to_sign =
      "AWS4-HMAC-SHA256\n#{@amz_date}\n#{date_stamp}/#{region}/s3/aws4_request\n" <>
        canonical_hash

    :crypto.mac(:hmac, :sha256, k_signing, string_to_sign) |> Base.encode16(case: :lower)
  end
end
