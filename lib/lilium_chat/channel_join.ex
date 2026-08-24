defmodule LiliumChat.ChannelJoin do
  @moduledoc """
  Join public channel (contract §5.7, issue #13): `channel.join`, executed
  on the per-channel writer (D13).

  Mirrors the old Worker `ChatChannel.joinChannel` (`membership.ts`):

  * entry gate: `CHANNEL_NOT_FOUND` / `CHANNEL_DISSOLVED` /
    `UNSUPPORTED_CHANNEL_KIND` (DM channels are not joinable) — before the
    cheap idempotency pre-check (old Worker order);
  * the visibility gate applies to non-members only: a non-member may join
    `visibility = "public_listed"` channels, already-active members bypass
    the gate (the no-op returns their EXISTING role — old Worker P0-4);
  * fresh join / rejoin after `left`: role resets to `member`,
    `member_count` + `membership_version` bump, `member.joined`
    (`join_source: "public"`) + the §10.4 `system.notice` (v2 delta: the
    old Worker emits no notice here) + the `channel_joined` user hint to
    the joiner (D8).

  The idempotency `request_hash` is `{user_id}` (old Worker parity: the
  body is empty, the caller is the differentiator). Returns
  `{result, new_seq}` with the same tagged results as
  `LiliumChat.ChannelLifecycle.create/3` (`kind: :joined` / `:cached` /
  `:error`).
  """

  alias LiliumChat.{
    CanonicalJSON,
    ChannelEvents,
    Errors,
    Idempotency,
    Ids,
    Profiles,
    Projections,
    Query,
    Repo
  }

  @doc """
  Join the channel (`POST /api/chat/channels/{channel_id}/join`, §5.7).
  `input` is `%{user_id: binary, command_id: binary}`.
  """
  def join(channel_id, seq, input) do
    user_id = input[:user_id]
    command_id = input[:command_id]

    # Old Worker order: the meta gate runs BEFORE the cheap pre-check.
    case join_gate(load_meta_full(channel_id)) do
      {:error, %Errors.ApiError{} = api_error} ->
        {%{kind: :error, error: api_error}, seq}

      {:ok, _meta} ->
        request_hash = CanonicalJSON.encode_and_sha256([{"user_id", user_id}])

        case Idempotency.check("user", user_id, "channel.join", command_id, request_hash) do
          {:cached, response} ->
            {%{kind: :cached, response: response}, seq}

          _ ->
            do_join(channel_id, seq, user_id, command_id, request_hash)
        end
    end
  end

  # ------------------------------------------------------------------------

  # DM channels are not joinable; dissolved channels reject everyone.
  defp join_gate(nil), do: {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found")}

  defp join_gate(meta) do
    case meta do
      %{"status" => "dissolved"} ->
        {:error, Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")}

      %{"kind" => kind} when kind != "channel" ->
        {:error,
         Errors.new("UNSUPPORTED_CHANNEL_KIND", "operation not supported for DM channels")}

      _ ->
        {:ok, meta}
    end
  end

  defp do_join(channel_id, seq, user_id, command_id, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    case Idempotency.run_writer_operation(
           "user",
           user_id,
           "channel.join",
           command_id,
           request_hash,
           fn ->
             # Re-read inside the txn (concurrent joins / dissolve).
             case load_meta_full(channel_id) do
               nil ->
                 Repo.rollback(%{
                   kind: :error,
                   error: Errors.new("CHANNEL_NOT_FOUND", "channel not found")
                 })

               meta ->
                 if meta["status"] == "dissolved" do
                   Repo.rollback(%{
                     kind: :error,
                     error: Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
                   })
                 else
                   join_inner(channel_id, seq, user_id, meta, now, now_ms)
                 end
             end
           end
         ) do
      {:ok, %{kind: :joined, seq: new_seq} = payload} ->
        {Map.delete(payload, :seq), new_seq}

      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :cached, response: response}, seq}

      {:error, api_error} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  defp join_inner(channel_id, seq, user_id, meta, now, now_ms) do
    member = member_row(channel_id, user_id)

    case member do
      %{"status" => "active"} ->
        # Already-active no-op (old Worker P0-3/P0-4): the idempotency row
        # records the EXISTING membership (role + joined_at) so a retry
        # after a later leave is not mistaken for a real rejoin.
        %{
          kind: :joined,
          response: %{
            "channel" => join_channel_obj(meta, member["role"]),
            "membership" => %{
              "role" => member["role"],
              "joined_at" => Projections.format_ts(member["joined_at"])
            }
          },
          event_frames: [],
          user_hints: [],
          seq: seq
        }

      _ ->
        # Visibility gate (non-members only): public_listed is joinable.
        unless meta["visibility"] == "public_listed" do
          Repo.rollback(%{
            kind: :error,
            error: Errors.new("FORBIDDEN", "channel is not publicly joinable")
          })
        end

        # Fresh join OR rejoin (left/removed): role resets to `member`.
        mv = meta["membership_version"] + 1
        joined_at = Projections.format_ts(now)

        ChannelEvents.upsert_active_member(channel_id, user_id, now)

        Repo.query!(
          "UPDATE chat_v2.channels " <>
            "SET membership_version = $2, member_count = $3, updated_at = $4 WHERE channel_id = $1",
          [channel_id, mv, meta["member_count"] + 1, now],
          type: true
        )

        profiles = Profiles.resolve([user_id])
        {joined_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
        {notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)

        joined_payload = %{
          "channel_id" => channel_id,
          "user_id" => user_id,
          "role" => "member",
          "membership_version" => mv,
          "actor_kind" => "user",
          "actor_id" => user_id,
          "join_source" => "public",
          "inviter_user_id" => nil
        }

        ChannelEvents.insert_event(
          joined_id,
          "member.joined",
          channel_id,
          joined_payload,
          mv,
          now
        )

        notice = ChannelEvents.notice_payload("member.joined", user_id, user_id)
        ChannelEvents.insert_notice_event(notice_id, channel_id, user_id, notice, mv, now)

        frames = [
          ChannelEvents.event_frame(
            joined_id,
            "member.joined",
            channel_id,
            now,
            joined_payload,
            mv,
            profiles
          ),
          ChannelEvents.notice_frame(notice_id, channel_id, now, notice, mv, profiles)
        ]

        %{
          kind: :joined,
          response: %{
            "channel" =>
              join_channel_obj(Map.put(meta, "member_count", meta["member_count"] + 1), "member"),
            "membership" => %{"role" => "member", "joined_at" => joined_at}
          },
          event_frames: frames,
          # D8: join — the joiner's live sessions refresh.
          user_hints: [{user_id, "channel_joined"}],
          seq: s2
        }
    end
  end

  # §5.7 channel field (old Worker `joinChannelHandler` parity): the
  # `getSummary` projection minus the last-message / last-event fields.
  # `role` is the caller's (post-join) active role.
  defp join_channel_obj(meta, role) do
    %{
      "channel_id" => meta["channel_id"],
      "kind" => meta["kind"],
      "visibility" => meta["visibility"],
      "title" => meta["title"],
      "topic" => meta["topic"],
      "avatar_url" => meta["avatar_url"],
      "member_count" => meta["member_count"],
      "role" => role,
      "status" => meta["status"],
      "created_at" => Projections.format_ts(meta["created_at"]),
      "updated_at" => Projections.format_ts(meta["updated_at"])
    }
  end

  # ------------------------------------------------------------------ helpers

  defp load_meta_full(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT channel_id, kind, visibility, title, topic, avatar_url, status,
               member_count, membership_version, created_at, updated_at
        FROM chat_v2.channels
        WHERE channel_id = $1
        """,
        [channel_id],
        type: true
      )
    )
    |> List.first()
  end

  defp member_row(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT role, joined_at, status FROM chat_v2.channel_members " <>
          "WHERE channel_id = $1 AND user_id = $2",
        [channel_id, user_id],
        type: true
      )
    )
    |> List.first()
  end
end
