defmodule LiliumChatWeb.ReadFixtures do
  @moduledoc """
  Shared seed helpers for the read-path tests (issue #6).

  Import into a `LiliumChat.DataCase` / `LiliumChatWeb.ConnCase` module:

      import LiliumChatWeb.ReadFixtures

  All helpers insert real `chat_v2` / `public.users` rows so the domain reads can
  be exercised end-to-end. `seed_message/5` also writes the paired
  `message.created` event (same `event_id`) so replay re-projection can be tested.
  """

  alias LiliumChat.{Ids, Repo}

  @doc """
  A deterministic, monotonically-ordered event_id (UUIDv7-shaped) for `n`.
  Lexicographic order == insertion order, which is how the read path pages.
  """
  def eid(n),
    do: "00000000-0000-7000-8000-" <> String.pad_leading(Integer.to_string(n, 16), 12, "0")

  @doc "A base64url per-channel cursor map (`cursors`, contract §10.3)."
  def cursors_param(map) do
    map
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc "Insert a channel row."
  def seed_channel(channel_id, opts \\ []) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.channels (channel_id, kind, visibility, title, topic, avatar_url,
        status, created_by, created_at, updated_at, member_count, membership_version)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9, $10, 1)
      """,
      [
        channel_id,
        Keyword.get(opts, :kind, "channel"),
        Keyword.get(opts, :visibility, "private"),
        Keyword.get(opts, :title, "Channel #{String.slice(channel_id, 0, 6)}"),
        Keyword.get(opts, :topic, "topic"),
        Keyword.get(opts, :avatar_url, nil),
        Keyword.get(opts, :status, "active"),
        Keyword.get(opts, :created_by, "creator"),
        Keyword.get(opts, :created_at, now),
        Keyword.get(opts, :member_count, 1)
      ],
      type: true
    )

    channel_id
  end

  @doc "Insert a channel membership row."
  def seed_membership(channel_id, user_id, role, opts \\ []) do
    Repo.query!(
      """
      INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, left_at, status)
      VALUES ($1, $2, $3, $4, $5, $6)
      """,
      [
        channel_id,
        user_id,
        role,
        Keyword.get(opts, :joined_at, DateTime.utc_now()),
        Keyword.get(opts, :left_at, nil),
        Keyword.get(opts, :status, "active")
      ],
      type: true
    )
  end

  @doc """
  Insert a message row plus its paired timeline event (default `message.created`).

  `opts`: `:event_id`, `:status`, `:stream_state`, `:type`, `:format`, `:reply_to`,
  `:reply_snapshot` (map), `:invocation` (map), `:event_type`, `:event` (bool, default true).
  Returns the message_id.
  """
  def seed_message(message_id, channel_id, sender_id, text, opts \\ []) do
    event_id = Keyword.get(opts, :event_id) || Ecto.UUID.generate()
    now = Keyword.get(opts, :created_at, DateTime.utc_now())
    status = Keyword.get(opts, :status, "normal")

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (message_id, command_id, dedupe_principal_key, channel_id,
        sender_kind, sender_user_id, type, format, status, text, reply_to,
        reply_snapshot_json, stream_state, invocation_json,
        created_at, updated_at, edited_at, deleted_at, deleted_by, recalled_at, event_id)
      VALUES ($1, $2, $2, $3, 'user', $4, $5, $6, $7, $8, $9, $10, $11, $12,
        $13, $13, NULL, NULL, NULL, NULL, $14)
      """,
      [
        message_id,
        Keyword.get(opts, :command_id) || Ecto.UUID.generate(),
        channel_id,
        sender_id,
        Keyword.get(opts, :type, "text"),
        Keyword.get(opts, :format, "plain"),
        status,
        text,
        Keyword.get(opts, :reply_to, nil),
        Keyword.get(opts, :reply_snapshot, nil),
        Keyword.get(opts, :stream_state, "none"),
        Keyword.get(opts, :invocation, nil),
        now,
        event_id
      ],
      type: true
    )

    if Keyword.get(opts, :event, true) do
      seed_event(
        event_id,
        channel_id,
        Keyword.get(opts, :event_type, "message.created"),
        %{"message" => %{"message_id" => message_id}},
        actor_kind: "user",
        actor_id: sender_id,
        occurred_at: now
      )
    end

    message_id
  end

  @doc "Insert an events row with a JSONB payload."
  def seed_event(event_id, channel_id, event_type, payload, opts \\ []) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (event_id, event_type, channel_id, actor_kind, actor_id,
        actor_session_id, payload, membership_version_at_event, occurred_at)
      VALUES ($1, $2, $3, $4, $5, NULL, $6, 1, $7)
      """,
      [
        event_id,
        event_type,
        channel_id,
        Keyword.get(opts, :actor_kind, "system"),
        Keyword.get(opts, :actor_id, nil),
        payload,
        Keyword.get(opts, :occurred_at, DateTime.utc_now())
      ],
      type: true
    )

    event_id
  end

  @doc "Insert a public.users profile row."
  def seed_profile(user_id, full_name, avatar_url) do
    # `user_id` is a `uuid` column (issue #27): Postgrex needs the 16-byte
    # binary form, not the hyphenated string.
    Repo.query!(
      """
      INSERT INTO public.users (user_id, full_name, avatar_url)
      VALUES ($1, $2, $3)
      ON CONFLICT (user_id) DO UPDATE SET full_name = $2, avatar_url = $3
      """,
      [Ids.uuid_bytes(user_id), full_name, avatar_url]
    )
  end

  @doc """
  Insert an `invites` row (contract §5.8/§5.9/§5.10).

  `opts`: `:created_by` (default `"creator"`), `:channel_id`, `:expires_at`
  (default now+7d), `:max_uses`, `:used_count`, `:revoked_at`, `:created_at`.
  Returns the invite_code.
  """
  def seed_invite(invite_code, channel_id, opts \\ []) do
    Repo.query!(
      """
      INSERT INTO chat_v2.invites (invite_code, created_by, channel_id, expires_at, max_uses,
        used_count, revoked_at, created_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [
        invite_code,
        Keyword.get(opts, :created_by, "creator"),
        channel_id,
        Keyword.get(opts, :expires_at, DateTime.utc_now() |> DateTime.add(7, :day)),
        Keyword.get(opts, :max_uses, nil),
        Keyword.get(opts, :used_count, 0),
        Keyword.get(opts, :revoked_at, nil),
        Keyword.get(opts, :created_at, DateTime.utc_now())
      ],
      type: true
    )

    invite_code
  end

  @doc """
  Insert a `personal_stickers` row (contract §8.3).

  `opts`: `:url`, `:mime_type`, `:width`, `:height`, `:size_bytes`, `:blurhash`,
  `:created_at`, `:deleted_at`. Returns the sticker_id.
  """
  def seed_personal_sticker(sticker_id, user_id, attachment_id, opts \\ []) do
    Repo.query!(
      """
      INSERT INTO chat_v2.personal_stickers (sticker_id, user_id, attachment_id, url,
        mime_type, width, height, size_bytes, blurhash, created_at, deleted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [
        sticker_id,
        user_id,
        attachment_id,
        Keyword.get(opts, :url, "https://s3.example.com/#{attachment_id}"),
        Keyword.get(opts, :mime_type, "image/png"),
        Keyword.get(opts, :width, 512),
        Keyword.get(opts, :height, 512),
        Keyword.get(opts, :size_bytes, 12345),
        Keyword.get(opts, :blurhash, nil),
        Keyword.get(opts, :created_at, DateTime.utc_now()),
        Keyword.get(opts, :deleted_at, nil)
      ],
      type: true
    )

    sticker_id
  end

  @doc "Insert a read_state cursor row."
  def seed_read_state(user_id, channel_id, last_read_event_id) do
    Repo.query!(
      """
      INSERT INTO chat_v2.read_state (user_id, channel_id, last_read_event_id, updated_at)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (user_id, channel_id) DO UPDATE SET last_read_event_id = $3, updated_at = $4
      """,
      [user_id, channel_id, last_read_event_id, DateTime.utc_now()],
      type: true
    )
  end

  @doc """
  Insert a `pinned_message` pin row referencing an existing message.

  `message_projection_json` is built by
  `LiliumChat.ChannelPins.build_message_projection/4` — the same builder the
  real pin write path uses (contract §10.6 pin recovery snapshot).

  `opts`: `:pinned_by` (default: the message sender), `:priority` (default 10),
  `:projection_id`, `:created_at`. Returns the pin_id.
  """
  def seed_pin(pin_id, channel_id, source_message_id, opts \\ []) do
    row =
      Repo.query(
        "SELECT channel_id, sender_kind, sender_user_id, format, text, created_at FROM chat_v2.messages WHERE message_id = $1",
        [source_message_id],
        type: true
      )
      |> LiliumChat.Query.rows()
      |> List.first()

    now = Keyword.get(opts, :created_at, DateTime.utc_now())
    projection_id = Keyword.get(opts, :projection_id) || Ecto.UUID.generate()
    profiles = LiliumChat.Profiles.resolve([row["sender_user_id"]])

    projection =
      LiliumChat.ChannelPins.build_message_projection(row, projection_id, now, profiles)

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_pins (
        pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority,
        session_id, source_message_id, pinned_by_user_id, pinned_at, expires_at,
        last_pin_event_id, message_projection_json, created_at, updated_at
      )
      VALUES ($1, $2, 'pinned_message', 'user', $3, $4, NULL, $5, $3, $6, NULL,
              $7, $8, $6, $6)
      """,
      [
        pin_id,
        channel_id,
        Keyword.get(opts, :pinned_by, row["sender_user_id"]),
        Keyword.get(opts, :priority, 10),
        source_message_id,
        now,
        Ecto.UUID.generate(),
        Jason.encode!(projection)
      ],
      type: true
    )

    pin_id
  end

  @doc "Insert an attachment row."
  def seed_attachment(attachment_id, opts \\ []) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.attachments (attachment_id, owner_user_id, kind, filename, mime_type,
        size_bytes, width, height, blurhash, storage_key, url, status, created_at)
      VALUES ($1, $2, 'image', $3, $4, $5, $6, $7, $8, $9, $10, 'finalized', $11)
      """,
      [
        attachment_id,
        Keyword.get(opts, :owner_user_id, "owner"),
        Keyword.get(opts, :filename, "file.png"),
        Keyword.get(opts, :mime_type, "image/png"),
        Keyword.get(opts, :size_bytes, 1024),
        Keyword.get(opts, :width, 100),
        Keyword.get(opts, :height, 100),
        Keyword.get(opts, :blurhash, nil),
        Keyword.get(opts, :storage_key, "chat/#{attachment_id}"),
        Keyword.get(opts, :url, "https://s3.example.com/#{attachment_id}"),
        now
      ],
      type: true
    )

    attachment_id
  end

  @doc "Link an attachment to a message."
  def seed_message_attachment(message_id, attachment_id) do
    Repo.query!(
      "INSERT INTO chat_v2.message_attachments (message_id, attachment_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [message_id, attachment_id]
    )
  end

  @doc "Insert a mention row."
  def seed_mention(message_id, user_id, start_index, end_index) do
    Repo.query!(
      "INSERT INTO chat_v2.mentions (message_id, user_id, start_index, end_index) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
      [message_id, user_id, start_index, end_index]
    )
  end

  @doc "Insert a sticker snapshot row."
  def seed_sticker(message_id, opts \\ []) do
    Repo.query!(
      """
      INSERT INTO chat_v2.message_stickers (message_id, sticker_id, attachment_id, url,
        mime_type, width, height, size_bytes, blurhash)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        message_id,
        Keyword.get(opts, :sticker_id, Ecto.UUID.generate()),
        Keyword.get(opts, :attachment_id, Ecto.UUID.generate()),
        Keyword.get(opts, :url, "https://s3.example.com/sticker"),
        Keyword.get(opts, :mime_type, "image/png"),
        Keyword.get(opts, :width, 64),
        Keyword.get(opts, :height, 64),
        Keyword.get(opts, :size_bytes, 512),
        Keyword.get(opts, :blurhash, nil)
      ]
    )
  end
end
