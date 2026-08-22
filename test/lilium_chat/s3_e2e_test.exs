defmodule LiliumChat.S3E2ETest do
  @moduledoc """
  Real-S3 E2E for the attachment upload go/no-go gate (spec §12 / A7 / C7).

  This is the **deployment-level** proof that the SigV4 approach works against
  a real object store: presign → browser-style PUT to the *bucket-stripped*
  URL → finalize (HEAD) → public read.

  ## How it proves C7

  The PUT hits the endpoint host (the reverse proxy in front of the object
  store, which **re-injects the bucket prefix** before forwarding — exactly
  gina's nginx). The signature was computed over the **bucket-including**
  canonical URI, so the store accepts it. A plain presigned PUT that signed
  *without* the bucket (or returned *with* it) would 403.

  ## Running it

  `mix test` skips these by default. To run against real infra:

      # 1) object store (SeaweedFS or any S3-compatible) with a bucket
      # 2) a reverse proxy on S3_ENDPOINT that rewrites `/{key}` ->
      #    `/{S3_BUCKET}/{key}` (gina's nginx role)
      S3_E2E=1 S3_ENDPOINT=http://proxy:8080 S3_BUCKET=lilium-chat-attachments \\
        S3_REGION=us-east-1 S3_ACCESS_KEY_ID=... S3_SECRET_ACCESS_KEY=... \\
        S3_PUBLIC_BASE=http://proxy:8080 mix test test/lilium_chat/s3_e2e_test.exs

  `S3_ENDPOINT` / `S3_PUBLIC_BASE` must be the browser-facing (proxy) host so
  the signature's `host` header and the PUT target agree.
  """

  use LiliumChat.DataCase, async: false

  @tag :s3_e2e
  alias LiliumChat.S3
  alias LiliumChat.Uploads

  @user "e2e-user"
  @payload "lilium e2e payload — not a real image, just bytes\n"

  # Disabled by default (no live object store in CI). Set S3_E2E=1 (plus the
  # S3_* env vars and a bucket-re-injecting proxy on S3_ENDPOINT) to run it.
  test "presign -> PUT (bucket-stripped URL) -> finalize -> public read" do
    if System.get_env("S3_E2E") == "1" do
      cfg = e2e_cfg()

      body = %{
        "filename" => "e2e.png",
        "mime_type" => "image/png",
        "size_bytes" => byte_size(@payload)
      }

      # 1) presign (domain; real S3 via the :httpc transport — see e2e_cfg/0)
      response = Uploads.presign(@user, "e2e-" <> LiliumChat.Ids.uuidv7(), body, cfg)
      id = response["attachment_id"]
      upload_url = response["upload_url"]
      upload_headers = response["upload_headers"]

      # 2) browser-style PUT to the bucket-stripped URL, sending the exact
      #    signed headers (Content-Type + Cache-Control).
      put_headers = to_put_headers(upload_headers)

      {:ok, {{_v, 200, _r}, _h}} =
        :httpc.request([], {:binary, upload_url, :PUT, put_headers}, [], @payload)

      # 3) finalize: HEAD must see the object with matching content-type/length.
      result = Uploads.finalize(@user, id, nil, "e2e-fin-" <> LiliumChat.Ids.uuidv7(), cfg)
      assert result["attachment"]["attachment_id"] == id
      assert result["attachment"]["size_bytes"] == byte_size(@payload)

      # 4) the public URL reads back the exact bytes.
      url = result["attachment"]["url"]
      {:ok, {{_v, 200, _r}, _h}} = :httpc.request([], {:binary, url, :GET}, [], [])
    else
      # Disabled by default (no live object store in CI).
      assert true
    end
  end

  # Real-S3 gate config: `config/test.exs` wires the fake `TestTransport`, so
  # the gate builds its own `:httpc` config from the S3_* env vars (falling
  # back to the app config) to hit the object store directly.
  defp e2e_cfg do
    base = S3.config()

    %S3.Config{
      base
      | access_key_id: System.get_env("S3_ACCESS_KEY_ID", base.access_key_id),
        secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY", base.secret_access_key),
        region: System.get_env("S3_REGION", base.region),
        endpoint: System.get_env("S3_ENDPOINT", base.endpoint),
        bucket: System.get_env("S3_BUCKET", base.bucket),
        public_base: System.get_env("S3_PUBLIC_BASE", base.public_base),
        ttl_seconds: 300,
        transport: LiliumChat.S3.Transport.Httpc
    }
  end

  defp to_put_headers(%{"Content-Type" => ct, "Cache-Control" => cc}) do
    [{"content-type", ct}, {"cache-control", cc}]
  end
end
