defmodule LiliumChat.InviteCommands do
  @moduledoc """
  Invite write path (contract §5.8 / §5.9, issue #13): `channel.invite_create`
  + `channel.invite_accept`, executed on the per-channel writer (D13).

  Each command follows the `LiliumChat.ChannelLifecycle` pattern: payload
  validation, a cheap idempotency pre-check, then ONE PG transaction (D11,
  via `LiliumChat.Idempotency.run_writer_operation/6`) that re-checks
  idempotency, gates the channel, writes the business rows, and records the
  committed HTTP response in the single `idempotency` table (D10). Returns
  `{result, new_seq}` with the same tagged results as
  `LiliumChat.ChannelLifecycle.create/3`.

  * **create (§5.8)** — the invite code is the *personal stable* code
    (old Worker `personalInviteCode`): first 8 bytes hex of
    `SHA-256("lilium-invite:v1:<channel>:<user>")`, so a member re-creating
    an invite refreshes `expires_at` / `max_uses` and un-revokes the SAME
    code (upsert keyed on `invite_code`). Any active member may create
    (owner / admin / member). The v2 `invites` row carries `channel_id`
    as primary data (the vanished `invite_index` projection). No timeline
    event — the invite row + idempotency row only (old Worker parity: the
    old row went to the `invite_directory` outbox, not `events`).

  * **accept (§5.9)** — routed by `invite_code` (the URL has no
    `channel_id`): `route_for/1` resolves `invites.channel_id` pre-txn.
    v2 lag window: the invite row exists but `channel_id IS NULL` (import
    backfill pending) → `409 ROUTE_INDEX_PENDING` (retryable). A row
    pointing at a missing channel or an expired / revoked invite is
    `404 INVITE_NOT_FOUND`. Accepting writes the member row (fresh or
    rejoin), bumps `member_count` / `membership_version` / `used_count`,
    and emits `member.joined` (`join_source: "invite"`,
    `inviter_user_id` = the creator) + the §10.4 `system.notice`
    (v2 delta: the old Worker emits no notice here) + the `channel_joined`
    user hint to the joiner (D8).

  ## Conformance deltas vs the old Worker (contract v2.31 wins)

  * The accept response membership carries `status: "active"` (old Worker
    parity; the contract §5.9 example omits it).
  * `system.notice` is emitted on accept (old Worker emits none).
  * `ROUTE_INDEX_PENDING` is raised for the NULL-`channel_id` backfill
    window; the old Worker's lag window answered `INVITE_NOT_FOUND` (its
    `invite_index` was an outbox-fed projection).
  * Value-level type validation is stricter than the old Worker: a JSON
    float `expires_in_seconds` / `max_uses` 422s where JS
    `Number.isInteger` would accept it.
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

  @default_expires_seconds 604_800

  # ---------------------------------------------------------------- routing

  @doc """
  Resolve the accept route for an invite code (pre-txn, old Worker
  `InviteDirectory.previewInvite` parity).

  Returns:

  * `{:ok, channel_id}` — the invite row exists and is mapped to a channel;
  * `:route_index_pending` — the row exists but `channel_id IS NULL`
    (import backfill window → `409 ROUTE_INDEX_PENDING`);
  * `:invite_not_found` — no row at all (`404 INVITE_NOT_FOUND`).
  """
  def route_for(invite_code) do
    case Query.rows(
           Repo.query("SELECT channel_id FROM chat_v2.invites WHERE invite_code = $1", [
             invite_code
           ])
         ) do
      [%{"channel_id" => channel_id}] when is_binary(channel_id) ->
        {:ok, channel_id}

      [%{"channel_id" => _}] ->
        :route_index_pending

      _ ->
        :invite_not_found
    end
  end

  # ------------------------------------------------------------ create (§5.8)

  @doc """
  Create (or refresh) the caller's personal invite for a channel
  (`POST /api/chat/channels/{channel_id}/invites`, §5.8). `input` is
  `%{user_id: binary, command_id: binary, payload: map}`.
  """
  def create(channel_id, seq, input) do
    user_id = input[:user_id]
    command_id = input[:command_id]
    payload = input[:payload] || %{}

    # Old Worker order: payload validation (422) runs BEFORE the cached
    # idempotency check.
    with {:ok, parsed} <- parse_invite_create(payload) do
      request_hash = create_request_hash(channel_id, parsed)

      case Idempotency.check("user", user_id, "channel.invite_create", command_id, request_hash) do
        {:cached, response} ->
          {%{kind: :cached, response: response}, seq}

        _ ->
          do_create(channel_id, seq, user_id, command_id, parsed, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # -------------------------------------------------------------- accept (§5.9)

  @doc """
  Accept an invite (`POST /api/chat/invites/{invite_code}/accept`, §5.9).
  `channel_id` is the routing channel (from `route_for/1`); `input` is
  `%{user_id: binary, command_id: binary, invite_code: binary}`.
  """
  def accept(channel_id, seq, input) do
    user_id = input[:user_id]
    command_id = input[:command_id]
    invite_code = input[:invite_code]

    request_hash =
      CanonicalJSON.encode_and_sha256([
        {"channel_id", channel_id},
        {"invite_code", invite_code}
      ])

    case Idempotency.check("user", user_id, "channel.invite_accept", command_id, request_hash) do
      {:cached, response} ->
        {%{kind: :cached, response: response}, seq}

      _ ->
        do_accept(channel_id, seq, user_id, command_id, invite_code, request_hash)
    end
  end

  # ------------------------------------------------------------------ create

  defp parse_invite_create(payload) do
    with {:ok, expires} <- parse_expires(payload["expires_in_seconds"]),
         {:ok, max_uses} <- parse_max_uses(payload["max_uses"]) do
      {:ok, %{expires: expires, max_uses: max_uses}}
    end
  end

  # Old Worker: `expires_in_seconds ?? 604800` must be a positive integer.
  defp parse_expires(nil), do: {:ok, @default_expires_seconds}

  defp parse_expires(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_expires(_value),
    do: {:error, Errors.new("INVALID_MESSAGE", "expires_in_seconds must be a positive integer")}

  # Old Worker: `max_uses ?? null` must be null or a non-negative integer.
  defp parse_max_uses(nil), do: {:ok, nil}

  defp parse_max_uses(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_max_uses(_value),
    do: {:error, Errors.new("INVALID_MESSAGE", "max_uses must be a non-negative integer or null")}

  # Canonicalized request hash (old Worker parity): the defaults are baked
  # in, so a body without the fields hashes identically to one with the
  # defaults.
  defp create_request_hash(channel_id, parsed) do
    CanonicalJSON.encode_and_sha256([
      {"channel_id", channel_id},
      {"expires_in_seconds", parsed.expires},
      {"max_uses", parsed.max_uses}
    ])
  end

  defp do_create(channel_id, seq, user_id, command_id, parsed, request_hash) do
    now = DateTime.utc_now()

    case Idempotency.run_writer_operation(
           "user",
           user_id,
           "channel.invite_create",
           command_id,
           request_hash,
           fn ->
             case load_meta_full(channel_id) do
               nil ->
                 Repo.rollback(%{
                   kind: :error,
                   error: Errors.new("CHANNEL_NOT_FOUND", "channel not found")
                 })

               meta ->
                 cond do
                   meta["status"] == "dissolved" ->
                     Repo.rollback(%{
                       kind: :error,
                       error: Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
                     })

                   active_role(channel_id, user_id) == nil ->
                     Repo.rollback(%{
                       kind: :error,
                       error: Errors.new("FORBIDDEN", "only channel members may create invite")
                     })

                   true ->
                     upsert_invite(channel_id, seq, user_id, parsed, now)
                 end
             end
           end
         ) do
      {:ok, %{kind: :invite_created, seq: new_seq} = payload} ->
        {Map.delete(payload, :seq), new_seq}

      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :cached, response: response}, seq}

      {:error, api_error} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  defp upsert_invite(channel_id, seq, user_id, parsed, now) do
    code = personal_invite_code(channel_id, user_id)
    expires_at = DateTime.add(now, parsed.expires, :second)

    case invite_row(code) do
      nil ->
        Repo.query!(
          "INSERT INTO chat_v2.invites " <>
            "(invite_code, created_by, channel_id, expires_at, max_uses, used_count, revoked_at, created_at) " <>
            "VALUES ($1, $2, $3, $4, $5, 0, NULL, $6)",
          [code, user_id, channel_id, expires_at, parsed.max_uses, now],
          type: true
        )

      existing ->
        if existing["created_by"] != user_id do
          # Old Worker P0-6: two different members cannot own the same code
          # (the personal code is a pure (channel, user) hash — this only
          # fires on corrupted / pre-seeded state).
          Repo.rollback(%{
            kind: :error,
            error: Errors.new("CHAT_WORKER_UNAVAILABLE", "invite code collision")
          })
        else
          # Re-create = refresh TTL + max_uses and un-revoke (old Worker
          # `UPDATE ... SET revoked_at=NULL`).
          Repo.query!(
            "UPDATE chat_v2.invites SET expires_at = $3, max_uses = $4, revoked_at = NULL, channel_id = $5 " <>
              "WHERE invite_code = $1 AND created_by = $2",
            [code, user_id, expires_at, parsed.max_uses, channel_id],
            type: true
          )
        end
    end

    %{
      kind: :invite_created,
      response: %{
        "invite_code" => code,
        "expires_at" => Projections.format_ts(expires_at),
        "max_uses" => parsed.max_uses
      },
      # No timeline event (old Worker: the invite row went to the
      # `invite_directory` outbox, not `events`).
      event_frames: [],
      user_hints: [],
      seq: seq
    }
  end

  # ------------------------------------------------------------------ accept

  defp do_accept(channel_id, seq, user_id, command_id, invite_code, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    case Idempotency.run_writer_operation(
           "user",
           user_id,
           "channel.invite_accept",
           command_id,
           request_hash,
           fn ->
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
                   accept_inner(channel_id, seq, user_id, invite_code, meta, now, now_ms)
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

  defp accept_inner(channel_id, seq, user_id, invite_code, meta, now, now_ms) do
    invite = invite_row(invite_code)

    cond do
      invite == nil or invite["invite_code"] != invite_code ->
        Repo.rollback(%{kind: :error, error: Errors.new("INVITE_NOT_FOUND", "invite not found")})

      not invite_active?(invite, now) ->
        Repo.rollback(%{kind: :error, error: Errors.new("INVITE_NOT_FOUND", "invite not found")})

      true ->
        member = member_row(channel_id, user_id)

        cond do
          # Already active: no-op (old Worker parity) — the invite is NOT
          # consumed and the response returns the EXISTING membership.
          member != nil and member["status"] == "active" ->
            %{
              kind: :joined,
              response: %{
                "channel" => channel_lite(meta),
                "membership" => %{
                  "role" => member["role"],
                  "joined_at" => Projections.format_ts(member["joined_at"]),
                  "status" => "active"
                }
              },
              event_frames: [],
              user_hints: [],
              seq: seq
            }

          invite["max_uses"] != nil and invite["used_count"] >= invite["max_uses"] ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("INVITE_NOT_AVAILABLE", "invite max uses exceeded")
            })

          true ->
            commit_join(
              channel_id,
              seq,
              user_id,
              invite_code,
              invite["created_by"],
              meta,
              now,
              now_ms
            )
        end
    end
  end

  # Fresh join OR rejoin of a `left` / `removed` row: role resets to
  # `member`, `join_source: "invite"`, `inviter_user_id` = the invite
  # creator (old Worker `acceptInvite` parity).
  defp commit_join(channel_id, seq, user_id, invite_code, inviter_user_id, meta, now, now_ms) do
    mv = meta["membership_version"] + 1
    joined_at = Projections.format_ts(now)

    ChannelEvents.upsert_active_member(channel_id, user_id, now)

    Repo.query!(
      "UPDATE chat_v2.channels " <>
        "SET membership_version = $2, member_count = $3, updated_at = $4 WHERE channel_id = $1",
      [channel_id, mv, meta["member_count"] + 1, now],
      type: true
    )

    Repo.query!(
      "UPDATE chat_v2.invites SET used_count = used_count + 1 WHERE invite_code = $1",
      [invite_code],
      type: true
    )

    profiles = Profiles.resolve(Enum.uniq([user_id, inviter_user_id]))

    {joined_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
    {notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)

    joined_payload = %{
      "channel_id" => channel_id,
      "user_id" => user_id,
      "role" => "member",
      "membership_version" => mv,
      "actor_kind" => "user",
      "actor_id" => user_id,
      "join_source" => "invite",
      "inviter_user_id" => inviter_user_id
    }

    ChannelEvents.insert_event(joined_id, "member.joined", channel_id, joined_payload, mv, now)

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
        "channel" => channel_lite(Map.put(meta, "member_count", meta["member_count"] + 1)),
        "membership" => %{"role" => "member", "joined_at" => joined_at, "status" => "active"}
      },
      event_frames: frames,
      # D8: accept is a join — the joiner's live sessions refresh.
      user_hints: [{user_id, "channel_joined"}],
      seq: s2
    }
  end

  # §5.9 channel field (old Worker `acceptInvite` response parity): the
  # seven meta fields, no `topic` / `created_at` / `updated_at` / `role`.
  defp channel_lite(meta) do
    %{
      "channel_id" => meta["channel_id"],
      "kind" => meta["kind"],
      "visibility" => meta["visibility"],
      "title" => meta["title"],
      "avatar_url" => meta["avatar_url"],
      "member_count" => meta["member_count"],
      "status" => meta["status"]
    }
  end

  # ------------------------------------------------------------------ helpers

  defp personal_invite_code(channel_id, user_id) do
    :crypto.hash(:sha256, "lilium-invite:v1:#{channel_id}:#{user_id}")
    |> :binary.part(0, 8)
    |> Base.encode16(case: :lower)
  end

  defp load_meta_full(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT channel_id, kind, visibility, title, avatar_url, status,
               member_count, membership_version
        FROM chat_v2.channels
        WHERE channel_id = $1
        """,
        [channel_id],
        type: true
      )
    )
    |> List.first()
  end

  defp active_role(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT role FROM chat_v2.channel_members " <>
          "WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
        [channel_id, user_id]
      )
    )
    |> List.first()
    |> case do
      %{"role" => role} -> role
      _ -> nil
    end
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

  defp invite_row(invite_code) do
    Query.rows(
      Repo.query(
        "SELECT invite_code, created_by, channel_id, expires_at, max_uses, used_count, revoked_at " <>
          "FROM chat_v2.invites WHERE invite_code = $1",
        [invite_code],
        type: true
      )
    )
    |> List.first()
  end

  # Old Worker: expired (`expires_at <= now`) or revoked → not found.
  # `expires_at` decodes as %NaiveDateTime{} (`:utc_datetime_usec`); compare
  # like types (the stored wall time is UTC).
  defp invite_active?(row, now) do
    is_nil(row["revoked_at"]) and
      is_struct(row["expires_at"], NaiveDateTime) and
      row["expires_at"] > DateTime.to_naive(now)
  end
end
