defmodule LiliumChat.BotUploads do
  @moduledoc """
  Bot attachment upload domain (contract §9.17.1: Bot channel-scoped image
  upload).

  Port of the old Worker's `BotAttachmentMixin`
  (`src/do/chat-channel/handlers/bot-attachment-routes.ts`), the behavioral
  reference for gate order, error codes/messages and idempotency semantics:

  * `presign/5` — same wire shape as the user presign (contract §8.1) but
    channel-scoped: the bot must be **installed** in the channel (an `allowed`
    `chat_v2.channel_command_bindings` row), and the pending attachment row
    carries `owner_bot_id` + `channel_id` with `owner_user_id = NULL`.
    Idempotency uses the bot principal (`principal_kind='bot'`,
    `operation='bot.attachment.presign'` — the old Worker's exact operation
    string) and, like the old Worker, the request hash is channel-scoped.
  * `finalize/5` — channel gates, S3 `HEAD` (content-type + size must match),
    pending → finalized flip, contract §8.2 projection. No Idempotency-Key
    (the old Worker's bot finalize is not idempotency-keyed; the projection
    replay on an already-finalized attachment is the idempotency).

  Gate order (old Worker parity, both routes):

    1. channel exists → `CHANNEL_NOT_FOUND` (404)
    2. channel not dissolved → `CHANNEL_DISSOLVED` (409)
    3. bot installed in channel → `FORBIDDEN` (403) "bot not installed in channel"
  """

  alias LiliumChat.{Errors, Idempotency, Ids, Query, Repo, S3, Uploads}

  @principal_kind "bot"
  @presign_operation "bot.attachment.presign"

  # --------------------------------------------------------------- presign

  @doc """
  Create a pending bot-owned attachment + presigned PUT (contract §9.17.1).

  `body` is the decoded request map; the required-field pre-check
  ("filename, mime_type and size_bytes are required") runs BEFORE the channel
  gates, exactly like the old Worker's route-level check. Raises
  `LiliumChat.Errors.ApiError` on any gate failure.
  """
  def presign(bot_id, channel_id, idempotency_key, body, s3_cfg \\ S3.config()) do
    body = body || %{}

    if idempotency_key in [nil, ""] do
      raise_api("INVALID_MESSAGE", "Idempotency-Key required")
    end

    unless is_binary(body["filename"]) and is_binary(body["mime_type"]) and
             is_number(body["size_bytes"]) do
      raise_api("INVALID_MESSAGE", "filename, mime_type and size_bytes are required")
    end

    assert_channel(channel_id)
    assert_bot_installed(channel_id, bot_id)

    v = Uploads.validate_presign_body(body)
    request_hash = Uploads.presign_request_hash(v) <> "|channel=" <> channel_id

    Idempotency.run_operation(
      @principal_kind,
      bot_id,
      @presign_operation,
      idempotency_key,
      request_hash,
      fn ->
        do_new_presign(bot_id, channel_id, v, s3_cfg)
      end
    )
  end

  defp do_new_presign(bot_id, channel_id, v, s3_cfg) do
    now = DateTime.utc_now()
    attachment_id = Ids.uuidv7()
    storage_key = S3.attachment_object_key(attachment_id)
    url = S3.public_object_url(s3_cfg.public_base, storage_key)
    {upload_url, expires_at, upload_headers} = S3.presign_put(s3_cfg, storage_key, v.mime_type)

    insert_bot_attachment(
      attachment_id,
      bot_id,
      channel_id,
      v,
      storage_key,
      url,
      now
    )

    %{
      "attachment_id" => attachment_id,
      "upload_url" => upload_url,
      "upload_method" => "PUT",
      "upload_headers" => upload_headers,
      "expires_at" => expires_at
    }
  end

  # --------------------------------------------------------------- finalize

  @doc """
  Verify + finalize a pending bot-owned attachment (contract §9.17.1).

  `etag` is accepted (old Worker parity) but, as in the old Worker, not yet
  used by the HEAD check. No Idempotency-Key required.
  """
  def finalize(bot_id, channel_id, attachment_id, _etag \\ nil, s3_cfg \\ S3.config()) do
    if channel_id in [nil, ""] do
      raise_api("INVALID_MESSAGE", "channel_id required")
    end

    if attachment_id in [nil, ""] do
      raise_api("INVALID_MESSAGE", "attachment_id required")
    end

    assert_channel(channel_id)
    assert_bot_installed(channel_id, bot_id)

    row =
      find_attachment(attachment_id) ||
        raise_api("UNSUPPORTED_ATTACHMENT_TYPE", "attachment not found")

    # No channel filter in the lookup (old Worker parity) — the ownership
    # check below enforces both owner and channel.
    unless row["owner_bot_id"] == bot_id and row["channel_id"] == channel_id do
      raise_api("FORBIDDEN", "attachment does not belong to bot in this channel")
    end

    response = %{"attachment" => Uploads.project_attachment(row)}

    case row["status"] do
      "finalized" ->
        response

      "pending" ->
        head = S3.head_object(s3_cfg, row["storage_key"], row["mime_type"], row["size_bytes"])

        unless head[:ok] do
          raise_api("UNSUPPORTED_ATTACHMENT_TYPE", "S3 object missing or mismatch")
        end

        update_attachment_status(attachment_id, "finalized")

        response

      _ ->
        raise_api("UNSUPPORTED_ATTACHMENT_TYPE", "attachment cannot be finalized")
    end
  end

  # -------------------------------------------------------------- gates

  # Old Worker `soleChannelMetaKindStreamGate` + `assertNotDissolved` parity:
  # missing channel → 404, dissolved → 409 (message verbatim).
  defp assert_channel(channel_id) do
    case channel_status(channel_id) do
      nil -> raise_api("CHANNEL_NOT_FOUND", "channel not found")
      "dissolved" -> raise_api("CHANNEL_DISSOLVED", "channel is dissolved")
      _ -> :ok
    end
  end

  defp channel_status(channel_id) do
    case Query.rows(
           Repo.query(
             "SELECT status FROM chat_v2.channels WHERE channel_id = $1",
             [channel_id]
           )
         ) do
      [row | _] -> row["status"]
      [] -> nil
    end
  end

  # Old Worker `isBotInstalledInChannel` parity: at least one `allowed`
  # command binding for (channel, bot).
  defp assert_bot_installed(channel_id, bot_id) do
    installed? =
      Query.rows(
        Repo.query(
          """
          SELECT 1 AS ok
          FROM chat_v2.channel_command_bindings
          WHERE channel_id = $1 AND bot_id = $2 AND status = 'allowed'
          LIMIT 1
          """,
          [channel_id, bot_id]
        )
      ) != []

    unless installed? do
      raise_api("FORBIDDEN", "bot not installed in channel")
    end
  end

  # ------------------------------------------------------------- attachments

  defp insert_bot_attachment(
         attachment_id,
         bot_id,
         channel_id,
         v,
         storage_key,
         url,
         now
       ) do
    Repo.query!(
      """
      INSERT INTO chat_v2.attachments
        (attachment_id, owner_user_id, owner_bot_id, channel_id, kind, filename,
         mime_type, size_bytes, width, height, blurhash, storage_key, url,
         status, created_at)
      VALUES ($1, NULL, $2, $3, 'image', $4, $5, $6, $7, $8, $9, $10, $11, 'pending', $12)
      """,
      [
        attachment_id,
        bot_id,
        channel_id,
        v.filename,
        v.mime_type,
        v.size_bytes,
        v.width,
        v.height,
        v.blurhash,
        storage_key,
        url,
        now
      ]
    )
  end

  defp find_attachment(attachment_id) do
    case Query.rows(
           Repo.query(
             """
             SELECT attachment_id, owner_user_id, owner_bot_id, channel_id, kind,
                    filename, mime_type, size_bytes, width, height, blurhash,
                    storage_key, url, status, created_at
             FROM chat_v2.attachments
             WHERE attachment_id = $1
             LIMIT 1
             """,
             [attachment_id]
           )
         ) do
      [row | _] -> row
      [] -> nil
    end
  end

  defp update_attachment_status(attachment_id, status) do
    Repo.query!(
      "UPDATE chat_v2.attachments SET status = $2 WHERE attachment_id = $1",
      [attachment_id, status]
    )
  end

  # ------------------------------------------------------------------ helpers

  defp raise_api(code, message), do: raise(Errors.new(code, message))
end
