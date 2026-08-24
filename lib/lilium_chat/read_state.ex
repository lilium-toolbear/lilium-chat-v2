defmodule LiliumChat.ReadState do
  @moduledoc """
  `channel.mark_read` write path (contract §5.5, spec §5.1 / D12, issue #10).

  User-local (NOT a channel timeline command — handled on the browser
  connection, like the old Worker's UserConnection): the caller's
  `read_state` cursor is advanced **monotonically** (a same-or-older cursor is
  accepted and the stored value is returned — "return stored" semantics), and
  the committed ack carries `{channel_id, last_read_event_id, unread_count}`.

  There is NO timeline event (§5.5); on a real advance the user-local
  `read_state_updated` frame is broadcast to the user's OTHER live sessions on
  `user:<user_id>` (the calling session's pid is excluded — it just received
  the ack).

  The unread count follows the old Worker's `getUnreadCount`:
  `message.created` events after the stored cursor minus the caller's own.
  """

  alias LiliumChat.{Errors, Query, Repo}

  alias LiliumChat.WebSockets.Frames

  @doc """
  Apply `channel.mark_read`. `payload` carries `last_read_event_id` (a
  per-channel monotonic UUIDv7 string).

  Returns `{:ok, ack_frame}` or `{:error, %Errors.ApiError{}}`.
  """
  def mark_read(user_id, command_id, channel_id, payload) do
    case Map.get(payload || %{}, "last_read_event_id") do
      requested when is_binary(requested) and requested != "" ->
        do_mark_read(user_id, command_id, channel_id, requested)

      _ ->
        {:error, Errors.new("INVALID_MESSAGE", "last_read_event_id required")}
    end
  end

  defp do_mark_read(user_id, command_id, channel_id, requested) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        # An active `my_channels` (channel_members) row is required — the old
        # Worker's UserDirectory.updateReadState rejects a missing row with
        # FORBIDDEN "not an active member".
        member =
          Query.rows(
            Repo.query(
              "SELECT 1 AS x FROM chat_v2.channel_members " <>
                "WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
              [channel_id, user_id]
            )
          )

        if member == [] do
          Repo.rollback(%{kind: :error, error: Errors.new("FORBIDDEN", "not an active member")})
        else
          {stored, advanced} = upsert_cursor(user_id, channel_id, requested, now)
          unread = unread_count(channel_id, stored, user_id)
          %{kind: :ok, stored: stored, advanced: advanced, unread: unread}
        end
      end)

    case result do
      {:ok, %{stored: stored, advanced: advanced, unread: unread}} ->
        ack =
          Frames.command_ack("channel.mark_read", command_id, %{
            "channel_id" => channel_id,
            "last_read_event_id" => stored,
            "unread_count" => unread
          })

        if advanced do
          # User-local hint to the user's OTHER live sessions (the caller is
          # excluded via :sender_pid — see BrowserChannel handle_info).
          broadcast_read_state_updated(user_id, channel_id, stored, unread)
        end

        {:ok, ack}

      {:error, %{kind: :error, error: api_error}} ->
        {:error, api_error}

      # Unexpected PG failure — surface it loudly (txn rolls back).
      {:error, other} ->
        raise other
    end
  end

  # ---------------------------------------------------------------- internals

  # UUIDv7 cursors compare lexicographically == chronologically (the old
  # Worker compares the strings directly in SQLite). Same-or-older → "return
  # stored" (no error, no advance).
  #
  # The old Worker serialized a user's commands through ONE UserConnection DO;
  # v2 handles `mark_read` per socket, so the read-modify-write must be atomic
  # on its own: a single `INSERT ... ON CONFLICT ... DO UPDATE` keeps
  # `GREATEST(stored, requested)`, so two concurrent mark_reads on the same
  # (user, channel) neither lose an update nor double-INSERT on the PK.
  defp upsert_cursor(user_id, channel_id, requested, now) do
    stored_before =
      Query.rows(
        Repo.query(
          "SELECT last_read_event_id FROM chat_v2.read_state WHERE user_id = $1 AND channel_id = $2",
          [user_id, channel_id]
        )
      )
      |> List.first()
      |> case do
        nil -> nil
        %{"last_read_event_id" => current} -> current
      end

    stored_after =
      Query.rows(
        Repo.query(
          """
          INSERT INTO chat_v2.read_state (user_id, channel_id, last_read_event_id, updated_at)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (user_id, channel_id) DO UPDATE
          SET last_read_event_id = GREATEST(chat_v2.read_state.last_read_event_id, EXCLUDED.last_read_event_id),
              updated_at = $4
          RETURNING last_read_event_id
          """,
          [user_id, channel_id, requested, now]
        )
      )
      |> List.first()
      |> case do
        nil -> raise "read_state upsert returned no row"
        %{"last_read_event_id" => value} -> value
      end

    advanced = stored_before == nil or stored_after != stored_before
    {stored_after, advanced}
  end

  # old Worker getUnreadCount: total message.created events after the stored
  # cursor minus the caller's own (one bounded query).
  defp unread_count(channel_id, cursor, user_id) do
    case Repo.query(
           """
           SELECT
             (SELECT COUNT(*) FROM chat_v2.events
              WHERE channel_id = $1 AND event_type = 'message.created' AND event_id > $2)
             -
             (SELECT COUNT(*) FROM chat_v2.events
              WHERE channel_id = $1 AND event_type = 'message.created' AND actor_id = $3 AND event_id > $2)
             AS n
           """,
           [channel_id, cursor, user_id]
         ) do
      {:ok, %{rows: [[n]]}} -> max(0, n)
      _ -> 0
    end
  end

  defp broadcast_read_state_updated(user_id, channel_id, last_read_event_id, unread_count) do
    topic = "user:" <> user_id

    # The calling socket process is excluded (it already received the ack);
    # BrowserChannel drops the frame when self() == sender_pid.
    frame = Frames.read_state_updated(channel_id, last_read_event_id, unread_count)

    # Timed wrapper (spec §10 PubSub 广播延迟, issue #21).
    LiliumChat.Observability.broadcast(
      LiliumChat.PubSub,
      topic,
      {:broadcast_user, topic, frame, self()}
    )
  end
end
