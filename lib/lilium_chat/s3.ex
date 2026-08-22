defmodule LiliumChat.S3 do
  @moduledoc """
  S3 / SeaweedFS SigV4 presign + object helpers (spec §6.2, issue #14 / C7).

  ## The hidden compatibility point (C7)

  The PUT is **signed** with a path-style canonical URI that **includes the
  bucket** (`/{bucket}/{key}`), but the PUT URL **returned to the browser
  strips the bucket prefix** (`/{key}`). On gina, nginx re-injects the bucket
  prefix before forwarding to SeaweedFS, so the signature — computed over the
  bucket-including path — still verifies. If we signed *without* the bucket
  (or returned *with* it), the browser PUT would 403.

  ## Signature invariants (mirrors old `src/s3/presign.ts` + `url.ts`)

  * `Content-Type` + `Cache-Control` are **signed** (`allHeaders: true`);
    the browser must send exactly these headers (hence `upload_headers`).
  * Signed header set (sorted): `Cache-Control;Content-Type;host`.
  * The signed `host` header value is the **endpoint host** (the browser-facing
    host, e.g. the nginx/proxy host) — NOT the bucket path.
  * 5-minute TTL (`X-Amz-Expires`, default 300).
  * Payload hash is `UNSIGNED-PAYLOAD` — the Worker never sees the binary.

  The signing is **pure** (no HTTP) so it is fully unit-testable; only
  `head_object/4` touches the network via an injectable `transport` (see
  `LiliumChat.S3.Config.transport`).
  """

  alias LiliumChat.S3.Config

  @cache_control "public, max-age=31536000, immutable"
  @attachment_namespace "chat"

  # ------------------------------------------------------------------- types

  # S3 / SeaweedFS connection + signing config.
  defmodule Config do
    @moduledoc false
    defstruct [
      :access_key_id,
      :secret_access_key,
      :region,
      :endpoint,
      :bucket,
      :public_base,
      :ttl_seconds,
      :transport
    ]
  end

  # ---------------------------------------------------------------- config

  @doc """
  Build the default S3 config from app config (`:lilium_chat, :s3` + the
  `:s3_transport` override, spec §6.2). Read lazily so the app boots without
  S3 credentials present.
  """
  def config do
    s3 = Application.get_env(:lilium_chat, :s3) || []
    ttl = s3[:presign_ttl_seconds] || s3[:ttl_seconds] || 300

    %Config{
      access_key_id: s3[:access_key_id],
      secret_access_key: s3[:secret_access_key],
      region: s3[:region] || "us-east-1",
      endpoint: s3[:endpoint],
      bucket: s3[:bucket],
      public_base: s3[:public_base],
      ttl_seconds: ttl,
      transport: Application.get_env(:lilium_chat, :s3_transport, LiliumChat.S3.Transport.Httpc)
    }
  end

  @doc "The immutable public-read Cache-Control value (old `PUBLIC_OBJECT_CACHE_CONTROL`)."
  def public_object_cache_control, do: @cache_control

  # ------------------------------------------------------------ object keys

  @doc """
  Object storage key for an image attachment.

  Matches the contract (§8.1/§8.2/§3.6) where the key embeds only the
  high-entropy `attachment_id` under the `chat/` namespace — no filename,
  user, channel or extension. (`filename`/`mime_type` are accepted for
  signature compatibility with the old helper but do not affect the key.)
  """
  def attachment_object_key(attachment_id, _filename \\ nil, _mime_type \\ nil) do
    @attachment_namespace <> "/" <> attachment_id
  end

  # --------------------------------------------------------------- URL bits

  @doc "Path SeaweedFS sees after nginx re-injects the bucket: `/{bucket}/{key}`."
  def weed_pathname(bucket, key) do
    b = bucket |> String.trim("/")
    k = key |> String.trim_leading("/")
    "/" <> b <> "/" <> k
  end

  @doc "Path-style URL **including** the bucket (used for signing)."
  def object_url(endpoint, bucket, key) do
    base = endpoint |> String.trim_trailing("/")
    base <> weed_pathname(bucket, key)
  end

  @doc """
  Browser PUT/HEAD URL: same host + query as the signed URL, path **without**
  the bucket prefix (nginx re-injects it). Mirrors old `s3BrowserUploadUrl/2`.
  """
  def browser_upload_url(signed_url, key) do
    {base, query} =
      case String.split(signed_url, "?", parts: 2) do
        [a] -> {a, ""}
        [a, q] -> {a, q}
      end

    uri = URI.parse(base)
    authority = "#{uri.scheme}://" <> host_with_optional_port(uri)

    authority <>
      "/" <> String.trim_leading(key, "/") <> if query == "", do: "", else: "?" <> query
  end

  @doc "Clean public-read URL (`{publicBase}/{key}`); nginx injects the bucket."
  def public_object_url(public_base, key) do
    base = public_base |> String.trim_trailing("/")
    key = key |> String.trim_leading("/")
    base <> "/" <> key
  end

  # --------------------------------------------------------------- presign

  @doc """
  Sign a presigned PUT for `key` with `content_type`.

  Returns `{upload_url, expires_at, upload_headers}` where:
    * `upload_url` is the bucket-stripped PUT URL the browser hits;
    * `expires_at` is `now + ttl_seconds` (ISO 8601, UTC);
    * `upload_headers` are the exact headers the browser must send
      (`Content-Type` + `Cache-Control`, both signed).

  `now` is injectable (defaults to `DateTime.utc_now()`) for deterministic
  tests.
  """
  def presign_put(%Config{} = cfg, key, content_type, now \\ DateTime.utc_now())
      when is_struct(now, DateTime) do
    amz_date = format_amz_date(now)
    date_stamp = amz_date |> String.slice(0, 8)
    credential_scope = "#{date_stamp}/#{cfg.region}/s3/aws4_request"
    credential = "#{cfg.access_key_id}/#{credential_scope}"
    canonical = canonical_request(cfg, key, content_type, now)

    string_to_sign =
      "AWS4-HMAC-SHA256\n" <>
        amz_date <>
        "\n" <>
        credential_scope <> "\n" <> sha256_hex(canonical)

    signature = signing_key(cfg, date_stamp) |> hmac_hex(string_to_sign)

    signed_headers = "Cache-Control;Content-Type;host"

    # Build the final URL. The canonical query above used the sorted, encoded
    # form for signing; the URL query only needs to carry the same params (S3
    # re-canonicalizes on its side), so we emit them in a stable order plus the
    # signature.
    url_query =
      [
        "X-Amz-Algorithm=AWS4-HMAC-SHA256",
        "X-Amz-Credential=" <> uri_encode(credential),
        "X-Amz-Date=" <> amz_date,
        "X-Amz-Expires=" <> Integer.to_string(cfg.ttl_seconds),
        "X-Amz-SignedHeaders=" <> uri_encode(signed_headers),
        "X-Amz-Signature=" <> signature
      ]
      |> Enum.join("&")

    upload_url =
      cfg.endpoint
      |> String.trim_trailing("/")
      |> Kernel.<>("/" <> String.trim_leading(key, "/") <> "?" <> url_query)

    expires_at = format_iso_second(now |> DateTime.add(cfg.ttl_seconds, :second))

    upload_headers = %{"Content-Type" => content_type, "Cache-Control" => @cache_control}

    {upload_url, expires_at, upload_headers}
  end

  @doc """
  HEAD an object by storage key via the public (bucket-stripped) URL and
  confirm it matches `expected_content_type` + `expected_size`.

  Returns `%{ok: true, content_type: ..., content_length: ...}` on a full
  match, or `%{ok: false, ...}` otherwise. Network errors resolve to
  `ok: false` (mirrors old `headObjectKey/4`).
  """
  def head_object(%Config{} = cfg, key, expected_content_type, expected_size) do
    url = public_object_url(cfg.public_base, key)

    case cfg.transport.head(url) do
      {:ok, status, headers} when status in 200..299 ->
        content_type = header_value(headers, "content-type")
        content_length = header_value(headers, "content-length") |> to_int()

        ok? =
          content_type == expected_content_type and
            content_length == expected_size

        %{ok: ok?, content_type: content_type, content_length: content_length}

      {:ok, status, _headers} ->
        %{ok: false, status: status}

      {:error, reason} ->
        %{ok: false, reason: reason}
    end
  end

  @doc """
  The signed canonical request (exposed for tests / conformance). It is the
  heart of SigV4: method, bucket-including canonical URI, canonical query,
  canonical headers, signed-headers list and the payload hash.
  """
  def canonical_request(%Config{} = cfg, key, content_type, now \\ DateTime.utc_now())
      when is_struct(now, DateTime) do
    amz_date = format_amz_date(now)
    date_stamp = amz_date |> String.slice(0, 8)
    credential_scope = "#{date_stamp}/#{cfg.region}/s3/aws4_request"
    credential = "#{cfg.access_key_id}/#{credential_scope}"
    host = host_of(cfg.endpoint)
    signed_headers = "Cache-Control;Content-Type;host"

    canonical_headers =
      "Cache-Control:" <>
        @cache_control <>
        "\nContent-Type:" <> content_type <> "\nhost:" <> host

    "PUT\n" <>
      canonical_uri(cfg.bucket, key) <>
      "\n" <>
      sign_query_params(cfg, amz_date, credential) <>
      "\n" <>
      canonical_headers <>
      "\n\n" <>
      signed_headers <> "\n" <> "UNSIGNED-PAYLOAD"
  end

  # ------------------------------------------------------------ SigV4 core

  # Sorted, RFC3986-encoded query string used for BOTH the canonical request
  # and the emitted URL (order-independent: S3 re-canonicalizes the query).
  defp sign_query_params(cfg, amz_date, credential) do
    [
      {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
      {"X-Amz-Credential", credential},
      {"X-Amz-Date", amz_date},
      {"X-Amz-Expires", Integer.to_string(cfg.ttl_seconds)}
    ]
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> uri_encode(k) <> "=" <> uri_encode(v) end)
    |> Enum.join("&")
  end

  # The canonical URI is the bucket-including path, URI-encoded per segment.
  defp canonical_uri(bucket, key) do
    path = weed_pathname(bucket, key)

    path
    |> String.split("/", trim: false)
    |> Enum.map_join("/", &uri_encode/1)
  end

  defp signing_key(%Config{} = cfg, date_stamp) do
    k_date = hmac_bin("AWS4" <> cfg.secret_access_key, date_stamp)
    k_region = hmac_bin(k_date, cfg.region)
    k_service = hmac_bin(k_region, "s3")
    hmac_bin(k_service, "aws4_request")
  end

  defp hmac_bin(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hmac_hex(key, data), do: key |> hmac_bin(data) |> Base.encode16(case: :lower)

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  # The `host` header the browser sends omits the default port for the scheme
  # (https→443, http→80); the canonical request's `host` must match it exactly.
  defp host_of(endpoint) do
    endpoint |> URI.parse() |> host_with_optional_port()
  end

  defp host_with_optional_port(%URI{} = uri) do
    base = uri.host || ""

    case uri.port do
      nil ->
        base

      port ->
        if port == default_port(uri.scheme),
          do: base,
          else: base <> ":" <> Integer.to_string(port)
    end
  end

  defp default_port("https"), do: 443
  defp default_port("wss"), do: 443
  defp default_port("http"), do: 80
  defp default_port("ws"), do: 80
  defp default_port(_), do: nil

  # Both formatters normalise to UTC via unix seconds (avoids `shift_zone!`,
  # which needs the full tz database; the container runs the UTC-only db).
  defp format_amz_date(%DateTime{} = dt) do
    dt = dt |> DateTime.to_unix() |> DateTime.from_unix!()

    "#{pad4(dt.year)}#{pad2(dt.month)}#{pad2(dt.day)}T" <>
      "#{pad2(dt.hour)}#{pad2(dt.minute)}#{pad2(dt.second)}Z"
  end

  # ISO-8601 with second precision (contract §8.1 `expires_at` format).
  defp format_iso_second(%DateTime{} = dt) do
    dt = dt |> DateTime.to_unix() |> DateTime.from_unix!()

    "#{pad4(dt.year)}-#{pad2(dt.month)}-#{pad2(dt.day)}T" <>
      "#{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)}Z"
  end

  defp pad2(n), do: Integer.to_string(n) |> String.pad_leading(2, "0")
  defp pad4(n), do: Integer.to_string(n) |> String.pad_leading(4, "0")

  # encodeURIComponent equivalent (safe set: A-Z a-z 0-9 - . _ ~), uppercase hex.
  defp uri_encode(str) do
    for <<c <- str>>, into: "" do
      encode_uri_char(c)
    end
  end

  defp encode_uri_char(c)
       when c in 65..90 or c in 97..122 or c in 48..57 or c in [45, 46, 95, 126] do
    <<c>>
  end

  defp encode_uri_char(c) do
    hi = div(c, 16) |> hex_char()
    lo = rem(c, 16) |> hex_char()
    <<?%, hi, lo>>
  end

  defp hex_char(n) do
    Integer.to_string(n, 16) |> String.upcase() |> String.to_charlist() |> Enum.at(0)
  end

  defp to_int(nil), do: nil
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case v |> to_string() |> Integer.parse() do
      {n, _} -> n
      :error -> nil
    end
  end

  defp header_value(headers, name) do
    name = String.downcase(to_string(name))

    headers =
      Enum.into(headers, %{}, fn
        {k, v} -> {String.downcase(to_string(k)), v}
      end)

    Map.get(headers, name)
  end
end
