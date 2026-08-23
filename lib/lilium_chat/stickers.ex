defmodule LiliumChat.Stickers do
  @moduledoc """
  Personal sticker library (contract §8.3, issues #7 / #15).

  Read path (issue #7):

  * `GET /api/chat/stickers?limit=&cursor=` — `list_for_user/2`: the caller's
    personal stickers, `created_at DESC`, keyset-paged by `created_at`.
    Pure read (A12): one statement.

  Write path (issue #15), mirroring the old Worker's `UserDirectory`
  `saveSticker` / `deleteSticker` (single PG transaction replaces the old
  two-DO coordination, spec D11):

  * `save/3` — `POST /api/chat/stickers`: resolve the source attachment
    (the caller's own finalized attachment, or a visible image/sticker
    message in the given channel), then get-or-create the caller's library
    item referencing the canonical `attachment_id`. No binary copy; the
    library is capped at `@library_limit` active items
    (`STICKER_LIBRARY_LIMIT_EXCEEDED`). A soft-deleted item is revived
    (fresh `created_at`), an active item is returned unchanged.
  * `delete/3` — `DELETE /api/chat/stickers/{sticker_id}`: soft-delete the
    caller's item (idempotent; deleting a missing item still succeeds). A
    sticker owned by another user is `FORBIDDEN`.

  Idempotency: the unified `chat_v2.idempotency` table (`namespace =
  'user_command'`, spec D10) via `LiliumChat.Idempotency` — operations
  `sticker.save` / `sticker.delete`, `operation_id` = the HTTP
  `Idempotency-Key`, one row per request, written in the same transaction as
  the mutation.

  Old-Worker quirk preserved: the save response's `created_at` is the
  CURRENT request time (not the stored row's `created_at`), so re-saving an
  existing item still reports a fresh timestamp — the stored idempotency
  response keeps replayed calls byte-stable.
  """

  alias LiliumChat.{CanonicalJSON, Errors, Idempotency, Ids, Projections, Query, Repo}

  @save_operation "sticker.save"
  @delete_operation "sticker.delete"

  # Contract §8.3 sticker library limit (old Worker MAX_PERSONAL_STICKERS).
  @library_limit 200

  # ------------------------------------------------------------------- read
  # (issue #7)

  @doc """
  List the caller's personal stickers page.

  `opts`: `:limit` (already clamped 1..100 by the controller; default 50),
  `:cursor` (opaque string or nil). Returns
  `%{items: [...], next_cursor: string | nil}`.
  """
  def list_for_user(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    cursor = decode_cursor(Keyword.get(opts, :cursor))
    {cursor_clause, params} = cursor_clause(cursor)

    rows =
      Repo.query(
        """
        SELECT sticker_id, attachment_id, url, mime_type, width, height,
               size_bytes, blurhash, created_at
        FROM chat_v2.personal_stickers
        WHERE user_id = $1 AND deleted_at IS NULL AND #{cursor_clause}
        ORDER BY created_at DESC
        LIMIT #{limit}
        """,
        [user_id | params],
        type: true
      )
      |> Query.rows()

    items = Enum.map(rows, &project_sticker_item/1)

    next_cursor =
      case items do
        [] -> nil
        [_ | _] -> NaiveDateTime.to_iso8601(List.last(rows)["created_at"])
      end

    %{items: items, next_cursor: next_cursor}
  end

  defp project_sticker_item(row) do
    %{
      "sticker_id" => row["sticker_id"],
      "created_at" => Projections.format_ts(row["created_at"]),
      "attachment" => attachment_projection(row)
    }
  end

  # Keyset predicate: `TRUE` on the first page, `created_at < $2` on a
  # follow-up page. `limit` is clamped to 1..100 by the caller, so the
  # interpolated `LIMIT #{limit}` is safe.
  defp cursor_clause(nil), do: {"TRUE", []}
  defp cursor_clause(cursor), do: {"created_at < $2", [cursor]}

  # The old Worker passes the raw cursor string straight to SQL
  # (`created_at < ?`). Here we accept ISO timestamps (full-precision, as
  # this endpoint emits them); anything unparseable is treated as "no
  # cursor" (first page) — the closest sane behaviour to the old Worker's
  # untyped SQLite string comparison.
  defp decode_cursor(nil), do: nil

  defp decode_cursor(""), do: nil

  defp decode_cursor(cursor) do
    case NaiveDateTime.from_iso8601(cursor) do
      {:ok, ndt} -> ndt
      _ -> nil
    end
  end

  # ------------------------------------------------------------------- save

  @doc """
  Save (or re-save) the caller's personal sticker for a source attachment
  (contract §8.3 保存, issue #15).

  `operation_id` is the HTTP `Idempotency-Key`; `body` is
  `%{"channel_id" => ..., "attachment_id" => ...}`. Returns the
  `{"sticker" => PersonalSticker}` response map.

  Error order (old Worker parity): `INVALID_MESSAGE` (missing fields) →
  `IDEMPOTENCY_CONFLICT` (same key, different body) → source resolution
  (`CHANNEL_NOT_FOUND` / `FORBIDDEN` / `INVALID_STICKER_SOURCE`) →
  `STICKER_LIBRARY_LIMIT_EXCEEDED`.

  A source attachment is accepted when either

    * the caller owns a **finalized** `attachments` row for it (the
      `pending_attachments` equivalent — no channel gate needed), or
    * the caller is an active member of `channel_id` and the attachment is
      linked to a **visible** (status normal/edited, type image/sticker)
      message in that channel (`resolveVisibleAttachment` equivalent).

  Saving neither copies the binary nor writes a channel timeline event.
  """
  def save(user_id, operation_id, body) when is_map(body) do
    channel_id = nonblank(body["channel_id"])
    attachment_id = nonblank(body["attachment_id"])

    if operation_id in [nil, ""] do
      raise Errors.new("INVALID_MESSAGE", "Idempotency-Key required")
    end

    if is_nil(channel_id) or is_nil(attachment_id) do
      raise Errors.new("INVALID_MESSAGE", "channel_id and attachment_id required")
    end

    request_hash = save_request_hash(channel_id, attachment_id)
    now = DateTime.utc_now()

    Idempotency.run_operation("user", user_id, @save_operation, operation_id, request_hash, fn ->
      projection = resolve_source_projection(user_id, channel_id, attachment_id)
      sticker_id = upsert_sticker(user_id, attachment_id, projection, now)

      %{
        "sticker" => %{
          "sticker_id" => sticker_id,
          "attachment" => attachment_projection(projection),
          # Old-Worker parity: the response timestamp is the current
          # request time, not the stored row's created_at.
          "created_at" => Projections.format_ts(now)
        }
      }
    end)
  end

  # ------------------------------------------------------------------ delete

  @doc """
  Soft-delete one of the caller's personal stickers (contract §8.3 删除,
  issue #15).

  `operation_id` is the HTTP `Idempotency-Key`. Returns the
  `{"sticker_id" => ..., "deleted" => true}` response map. Idempotent:
  deleting an already-deleted or missing item still succeeds and still
  records the idempotency row. A sticker owned by another user is
  `FORBIDDEN`; a missing `Idempotency-Key` is `INVALID_MESSAGE`.
  """
  def delete(user_id, operation_id, sticker_id) do
    if is_nil(operation_id) do
      raise Errors.new("INVALID_MESSAGE", "Idempotency-Key required")
    end

    if is_nil(sticker_id) do
      raise Errors.new("INVALID_MESSAGE", "sticker_id required")
    end

    request_hash = delete_request_hash(sticker_id)
    now = DateTime.utc_now()
    response = %{"sticker_id" => sticker_id, "deleted" => true}

    Idempotency.run_operation(
      "user",
      user_id,
      @delete_operation,
      operation_id,
      request_hash,
      fn ->
        row = find_sticker(sticker_id)

        # A row owned by someone else is FORBIDDEN; a missing row is an
        # idempotent no-op (old Worker parity: still records the
        # idempotency row and answers deleted:true).
        if row && row["user_id"] != user_id do
          raise Errors.new("FORBIDDEN", "sticker does not belong to user")
        end

        if row && row["deleted_at"] == nil do
          Repo.query!(
            "UPDATE chat_v2.personal_stickers SET deleted_at = $2 WHERE sticker_id = $1",
            [sticker_id, now]
          )
        end

        response
      end
    )
  end

  # ------------------------------------------------------------ resolution

  # The source-attachment projection: the caller's own finalized attachment
  # first (no channel gate — the old Worker checked `pending_attachments`
  # before ever touching the channel DO), otherwise a visible image/sticker
  # attachment inside the given channel (channel + membership gates + the
  # `visibleAttachmentInChannel` lookup).
  defp resolve_source_projection(user_id, channel_id, attachment_id) do
    case find_own_finalized_attachment(user_id, attachment_id) do
      nil -> resolve_channel_visible_attachment(user_id, channel_id, attachment_id)
      projection -> projection
    end
  end

  defp find_own_finalized_attachment(user_id, attachment_id) do
    Query.rows(
      Repo.query(
        "SELECT attachment_id, url, mime_type, width, height, size_bytes, blurhash " <>
          "FROM chat_v2.attachments " <>
          "WHERE attachment_id = $1 AND owner_user_id = $2 AND status = 'finalized'",
        [attachment_id, user_id]
      )
    )
    |> List.first()
  end

  # The `resolveVisibleAttachment` equivalent (old Worker ChatChannel
  # `channel-read.ts`): channel-exists gate → active-member gate → the
  # attachment's visible (status normal/edited, type image/sticker) link in
  # this channel, via `message_attachments` or `message_stickers` (one
  # UNIONed statement; the message_attachments link wins, matching the old
  # Worker's lookup order).
  defp resolve_channel_visible_attachment(user_id, channel_id, attachment_id) do
    # Gate 1: the channel exists.
    first_or_raise(
      "SELECT channel_id FROM chat_v2.channels WHERE channel_id = $1",
      [channel_id],
      "CHANNEL_NOT_FOUND",
      "channel not created"
    )

    # Gate 2: the saver is an active member of that channel.
    first_or_raise(
      "SELECT 1 AS x FROM chat_v2.channel_members " <>
        "WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
      [channel_id, user_id],
      "FORBIDDEN",
      "not a member"
    )

    # Gate 3: the attachment is linked to a visible message in this channel.
    first_or_raise(
      "SELECT p.attachment_id, p.url, p.mime_type, p.width, p.height, " <>
        "p.size_bytes, p.blurhash " <>
        "FROM ( " <>
        "SELECT a.attachment_id, a.url, a.mime_type, a.width, a.height, " <>
        "a.size_bytes, a.blurhash " <>
        "FROM chat_v2.attachments a " <>
        "JOIN chat_v2.message_attachments ma ON ma.attachment_id = a.attachment_id " <>
        "JOIN chat_v2.messages m ON m.message_id = ma.message_id " <>
        "WHERE a.attachment_id = $1 AND m.channel_id = $2 " <>
        "AND m.status IN ('normal', 'edited') AND m.type IN ('image', 'sticker') " <>
        "UNION ALL " <>
        "SELECT ms.attachment_id, ms.url, ms.mime_type, ms.width, ms.height, " <>
        "ms.size_bytes, ms.blurhash " <>
        "FROM chat_v2.message_stickers ms " <>
        "JOIN chat_v2.messages m ON m.message_id = ms.message_id " <>
        "WHERE ms.attachment_id = $1 AND m.channel_id = $2 " <>
        "AND m.status IN ('normal', 'edited') AND m.type IN ('image', 'sticker') " <>
        ") p " <>
        "LIMIT 1",
      [attachment_id, channel_id],
      "INVALID_STICKER_SOURCE",
      "attachment is not a visible image or sticker"
    )
  end

  # Run one raw query and return its first row, or raise the given ApiError
  # when the query is empty — the resolve-path gate idiom (channel exists,
  # membership, visible link).
  defp first_or_raise(query, params, code, message) do
    case Query.rows(Repo.query(query, params)) |> List.first() do
      nil -> raise Errors.new(code, message)
      row -> row
    end
  end

  # ----------------------------------------------------------------- upsert

  # Get-or-create the caller's library item for `attachment_id`
  # (unique `(user_id, attachment_id)`). A soft-deleted row is revived with
  # a fresh `created_at`; a missing row is inserted (subject to the
  # `@library_limit` cap); an active row is returned untouched.
  defp upsert_sticker(user_id, attachment_id, projection, now) do
    existing =
      Query.rows(
        Repo.query(
          "SELECT sticker_id, deleted_at FROM chat_v2.personal_stickers " <>
            "WHERE user_id = $1 AND attachment_id = $2",
          [user_id, attachment_id]
        )
      )
      |> List.first()

    case existing do
      nil ->
        count =
          Query.rows(
            Repo.query(
              "SELECT COUNT(*) AS n FROM chat_v2.personal_stickers " <>
                "WHERE user_id = $1 AND deleted_at IS NULL",
              [user_id]
            )
          )
          |> hd()
          |> Map.get("n")

        if count >= @library_limit do
          raise Errors.new("STICKER_LIBRARY_LIMIT_EXCEEDED", "personal sticker library is full")
        end

        sticker_id = Ids.uuidv7()

        # `ON CONFLICT` keeps the insert race-safe: if a concurrent save of
        # the same (user, attachment) with a different idempotency key
        # committed first, this upsert blocks on the unique index and then
        # no-ops (the WHERE excludes an already-active row), so RETURNING
        # returns no rows and we hand back the winner's library item.
        inserted =
          Query.rows(
            Repo.query(
              "INSERT INTO chat_v2.personal_stickers (sticker_id, user_id, attachment_id, url, " <>
                "mime_type, width, height, size_bytes, blurhash, created_at, deleted_at) " <>
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL) " <>
                "ON CONFLICT (user_id, attachment_id) DO UPDATE " <>
                "SET deleted_at = NULL, blurhash = EXCLUDED.blurhash, created_at = EXCLUDED.created_at " <>
                "WHERE personal_stickers.deleted_at IS NOT NULL " <>
                "RETURNING sticker_id",
              [
                sticker_id,
                user_id,
                attachment_id,
                projection["url"],
                projection["mime_type"],
                projection["width"],
                projection["height"],
                projection["size_bytes"],
                projection["blurhash"],
                now
              ]
            )
          )

        case inserted do
          [%{"sticker_id" => id} | _] -> id
          [] -> find_sticker_id(user_id, attachment_id)
        end

      %{"deleted_at" => deleted_at} when not is_nil(deleted_at) ->
        sticker_id = existing["sticker_id"]

        Repo.query!(
          "UPDATE chat_v2.personal_stickers SET deleted_at = NULL, blurhash = $2, created_at = $3 " <>
            "WHERE sticker_id = $1",
          [sticker_id, projection["blurhash"] || nil, now]
        )

        sticker_id

      %{"sticker_id" => sticker_id} ->
        sticker_id
    end
  end

  # ------------------------------------------------------------- helpers

  defp find_sticker_id(user_id, attachment_id) do
    Query.rows(
      Repo.query(
        "SELECT sticker_id FROM chat_v2.personal_stickers " <>
          "WHERE user_id = $1 AND attachment_id = $2",
        [user_id, attachment_id]
      )
    )
    |> List.first()
    |> Map.get("sticker_id")
  end

  defp find_sticker(sticker_id) do
    Query.rows(
      Repo.query(
        "SELECT sticker_id, user_id, deleted_at FROM chat_v2.personal_stickers " <>
          "WHERE sticker_id = $1",
        [sticker_id]
      )
    )
    |> List.first()
  end

  # The canonical attachment projection shared by the library list
  # (§8.3 PersonalSticker) and the save response: the stable image fields
  # without `filename` / `kind` / `storage_key`.
  defp attachment_projection(row) do
    %{
      "attachment_id" => row["attachment_id"],
      "url" => row["url"],
      "mime_type" => row["mime_type"],
      "width" => row["width"],
      "height" => row["height"],
      "size_bytes" => row["size_bytes"],
      "blurhash" => row["blurhash"]
    }
  end

  # Internal dedup key (not a wire field): deterministic per logical body,
  # canonical JSON SHA-256 (same convention as message.send, issue #9).
  defp save_request_hash(channel_id, attachment_id) do
    CanonicalJSON.encode_and_sha256([
      {"channel_id", channel_id},
      {"attachment_id", attachment_id}
    ])
  end

  defp delete_request_hash(sticker_id) do
    CanonicalJSON.encode_and_sha256([
      {"sticker_id", sticker_id}
    ])
  end

  defp nonblank(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp nonblank(_value), do: nil
end
