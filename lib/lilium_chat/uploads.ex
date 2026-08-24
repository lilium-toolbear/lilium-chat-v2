defmodule LiliumChat.Uploads do
  @moduledoc """
  Attachment upload domain (spec §6.2 / contract §8.1–§8.2, issue #14).

  Vertical slice for the C7 go/no-go gate:

  * `presign/4` — validates the request, mints a pending `chat_v2.attachments`
    row, signs a SigV4 PUT (bucket-including canonical URI, bucket-stripped
    PUT URL, `Content-Type` + `Cache-Control` signed, 5-min TTL) and returns
    the wire shape from contract §8.1.
  * `finalize/5` — confirms the pending attachment belongs to the user, does
    an S3 `HEAD` to verify the object exists with matching `Content-Type` and
    `Content-Length`, flips it to `finalized`, and returns the contract §8.2
    projection.

  Idempotency (`Idempotency-Key`) uses the single `chat_v2.idempotency`
  table (`namespace = 'user_command'`, spec D10): same key + same request
  hash replays the cached response; same key + different body →
  `IDEMPOTENCY_CONFLICT` (409). This matches the old `UserDirectory`
  semantics without the 2-phase pending insert (a single PG transaction is
  sufficient for the tracer bullet).
  """

  alias LiliumChat.Errors
  alias LiliumChat.Ids
  alias LiliumChat.Repo
  alias LiliumChat.S3

  @presign_operation "attachment.presign"
  @finalize_operation "attachment.finalize"
  @allowed_mimes ~w(image/png image/jpeg image/webp image/gif)
  @max_size 20 * 1024 * 1024
  @idempotency_ttl_seconds 24 * 60 * 60

  # --------------------------------------------------------------- presign

  @doc "Create a pending attachment + presigned PUT (contract §8.1)."
  def presign(user_id, idempotency_key, body, s3_cfg \\ S3.config()) do
    if idempotency_key in [nil, ""], do: raise_api("INVALID_MESSAGE", "Idempotency-Key required")

    body = body || %{}
    v = validate_presign_body(body)
    request_hash = presign_request_hash(v)
    now = DateTime.utc_now()

    with_idempotency(user_id, @presign_operation, idempotency_key, request_hash, fn ->
      do_new_presign(user_id, idempotency_key, v, request_hash, s3_cfg, now)
    end)
  end

  defp do_new_presign(user_id, idempotency_key, v, request_hash, s3_cfg, now) do
    attachment_id = Ids.uuidv7()
    storage_key = S3.attachment_object_key(attachment_id)
    url = S3.public_object_url(s3_cfg.public_base, storage_key)
    {upload_url, expires_at, upload_headers} = S3.presign_put(s3_cfg, storage_key, v.mime_type)

    response = %{
      "attachment_id" => attachment_id,
      "upload_url" => upload_url,
      "upload_method" => "PUT",
      "upload_headers" => upload_headers,
      "expires_at" => expires_at
    }

    insert_attachment(%{
      attachment_id: attachment_id,
      owner_user_id: user_id,
      kind: "image",
      filename: v.filename,
      mime_type: v.mime_type,
      size_bytes: v.size_bytes,
      width: v.width,
      height: v.height,
      blurhash: v.blurhash,
      storage_key: storage_key,
      url: url,
      status: "pending",
      created_at: now
    })

    insert_idempotency(
      user_id,
      @presign_operation,
      idempotency_key,
      request_hash,
      response,
      now
    )

    response
  end

  # --------------------------------------------------------------- finalize

  @doc "Verify + finalize a pending attachment (contract §8.2)."
  def finalize(user_id, attachment_id, etag, idempotency_key, s3_cfg \\ S3.config()) do
    if attachment_id in [nil, ""], do: raise_api("INVALID_MESSAGE", "attachment_id required")
    if idempotency_key in [nil, ""], do: raise_api("INVALID_MESSAGE", "Idempotency-Key required")

    request_hash = finalize_request_hash(attachment_id, etag)

    with_idempotency(user_id, @finalize_operation, idempotency_key, request_hash, fn ->
      do_finalize(user_id, attachment_id, idempotency_key, request_hash, s3_cfg)
    end)
  end

  defp do_finalize(user_id, attachment_id, idempotency_key, request_hash, s3_cfg) do
    row =
      find_attachment(attachment_id)
      |> case do
        nil -> raise_api("UNSUPPORTED_ATTACHMENT_TYPE", "attachment not found")
        r -> r
      end

    if row["owner_user_id"] != user_id do
      raise_api("FORBIDDEN", "attachment does not belong to user")
    end

    projection = project_attachment(row)
    response = %{"attachment" => projection}

    cond do
      row["status"] == "finalized" ->
        insert_idempotency(
          user_id,
          @finalize_operation,
          idempotency_key,
          request_hash,
          response,
          now()
        )

        response

      row["status"] == "pending" ->
        head = S3.head_object(s3_cfg, row["storage_key"], row["mime_type"], row["size_bytes"])

        unless head[:ok] do
          raise_api("UNSUPPORTED_ATTACHMENT_TYPE", "S3 object missing or mismatch")
        end

        update_attachment_status(attachment_id, "finalized")

        insert_idempotency(
          user_id,
          @finalize_operation,
          idempotency_key,
          request_hash,
          response,
          now()
        )

        response

      true ->
        raise_api("UNSUPPORTED_ATTACHMENT_TYPE", "attachment cannot be finalized")
    end
  end

  # ------------------------------------------------------------- projection

  # The Browser-visible finalized-attachment projection (contract §8.2).
  defp project_attachment(row) do
    %{
      "attachment_id" => row["attachment_id"],
      "kind" => row["kind"],
      "filename" => row["filename"],
      "mime_type" => row["mime_type"],
      "size_bytes" => row["size_bytes"],
      "width" => row["width"] || 0,
      "height" => row["height"] || 0,
      "blurhash" => row["blurhash"],
      "url" => row["url"]
    }
  end

  # ------------------------------------------------------------- validation

  defp validate_presign_body(body) do
    filename = body["filename"] |> to_string() |> String.trim()
    mime = body["mime_type"] |> to_string() |> String.trim() |> String.downcase()
    size = body["size_bytes"]
    width = validate_dim(body["width"])
    height = validate_dim(body["height"])
    blurhash = body["blurhash"]

    if filename == "" do
      raise_api("INVALID_MESSAGE", "filename required")
    end

    if mime == "" do
      raise_api("INVALID_MESSAGE", "mime_type required")
    end

    unless mime in @allowed_mimes do
      raise_api("UNSUPPORTED_ATTACHMENT_TYPE", "unsupported attachment type")
    end

    unless is_number(size) do
      raise_api("INVALID_MESSAGE", "size_bytes required")
    end

    unless size > 0 and size <= @max_size do
      raise_api("ATTACHMENT_TOO_LARGE", "attachment too large")
    end

    %{
      filename: filename,
      mime_type: mime,
      size_bytes: if(is_float(size), do: trunc(size), else: size),
      width: width,
      height: height,
      blurhash: blurhash
    }
  end

  defp validate_dim(nil), do: nil
  defp validate_dim(v) when is_integer(v) and v > 0, do: v
  defp validate_dim(v) when is_float(v) and v == trunc(v) and v > 0, do: trunc(v)
  defp validate_dim(_), do: raise_api("INVALID_MESSAGE", "dimension must be a positive integer")

  # --------------------------------------------------------------- request hash

  # Internal dedup key (not a wire field): deterministic per logical body.
  defp presign_request_hash(v) do
    "filename=" <>
      v.filename <>
      "|mime=" <>
      v.mime_type <>
      "|size=" <>
      Integer.to_string(v.size_bytes) <>
      "|w=" <>
      seg(v.width) <>
      "|h=" <>
      seg(v.height) <>
      "|blur=" <> seg(v.blurhash)
  end

  defp finalize_request_hash(attachment_id, etag) do
    "attachment_id=" <> attachment_id <> "|etag=" <> seg(etag)
  end

  defp seg(nil), do: "-"
  defp seg(v), do: to_string(v)

  # ------------------------------------------------------------- idempotency

  # Shared `Idempotency-Key` coordination for presign/finalize: replay the
  # cached response on a same-key + same-hash hit, raise IDEMPOTENCY_CONFLICT
  # on a same-key + different-body hit, otherwise run `do_new` (a zero-arity
  # function) and cache its response.
  defp with_idempotency(principal_id, operation, idempotency_key, request_hash, do_new) do
    {:ok, result} =
      Repo.transaction(fn ->
        case find_idempotency(principal_id, operation, idempotency_key) do
          row when is_map(row) ->
            cond do
              row["request_hash"] != request_hash -> raise_api("IDEMPOTENCY_CONFLICT")
              completed?(row) -> decode_json(row["response_json"])
              true -> do_new.()
            end

          nil ->
            do_new.()
        end
      end)

    result
  end

  defp completed?(row), do: row["status"] == "completed" and not is_nil(row["response_json"])

  defp find_idempotency(principal_id, operation, operation_id) do
    sql = """
    SELECT request_hash, status, response_json
    FROM chat_v2.idempotency
    WHERE namespace = 'user_command'
      AND principal_kind = 'user'
      AND principal_id = $1
      AND operation = $2
      AND operation_id = $3
    LIMIT 1
    """

    case Repo.query(sql, [principal_id, operation, operation_id], type: true) do
      {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
        case rows do
          [] -> nil
          [row | _] -> Map.new(Enum.zip(cols, row))
        end

      {:error, _} ->
        nil
    end
  end

  defp insert_idempotency(principal_id, operation, operation_id, request_hash, response, now) do
    sql = """
    INSERT INTO chat_v2.idempotency
      (id, namespace, principal_kind, principal_id, operation, operation_id,
       request_hash, status, response_json, created_at, updated_at, expires_at)
    VALUES ($1, 'user_command', 'user', $2, $3, $4, $5, 'completed', $6::jsonb, $7, $7, $8)
    """

    Repo.query!(sql, [
      Ids.uuid_bytes(Ids.uuidv7()),
      principal_id,
      operation,
      operation_id,
      request_hash,
      Jason.encode!(response),
      now,
      DateTime.add(now, @idempotency_ttl_seconds, :second)
    ])
  end

  # ------------------------------------------------------------- attachments

  defp find_attachment(attachment_id) do
    sql = """
    SELECT attachment_id, owner_user_id, kind, filename, mime_type, size_bytes,
           width, height, blurhash, storage_key, url, status, created_at
    FROM chat_v2.attachments
    WHERE attachment_id = $1
    LIMIT 1
    """

    case Repo.query(sql, [attachment_id], type: true) do
      {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
        case rows do
          [] -> nil
          [row | _] -> Map.new(Enum.zip(cols, row))
        end

      {:error, _} ->
        nil
    end
  end

  defp insert_attachment(row) do
    sql = """
    INSERT INTO chat_v2.attachments
      (attachment_id, owner_user_id, kind, filename, mime_type, size_bytes,
       width, height, blurhash, storage_key, url, status, created_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
    """

    Repo.query!(sql, [
      row.attachment_id,
      row.owner_user_id,
      row.kind,
      row.filename,
      row.mime_type,
      row.size_bytes,
      row.width,
      row.height,
      row.blurhash,
      row.storage_key,
      row.url,
      row.status,
      row.created_at
    ])
  end

  defp update_attachment_status(attachment_id, status) do
    Repo.query!(
      "UPDATE chat_v2.attachments SET status = $2 WHERE attachment_id = $1",
      [attachment_id, status]
    )
  end

  # ------------------------------------------------------------------ helpers

  defp decode_json(value) when is_map(value), do: value

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_json(value), do: value

  defp now, do: DateTime.utc_now()

  defp raise_api(code), do: raise_api(code, nil)

  defp raise_api(code, message), do: raise(Errors.new(code, message))
end
