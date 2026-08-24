defmodule LiliumChat.Dms do
  @moduledoc """
  DM get-or-create (contract §5.2c, issue #13): `dm.open`.

  `POST /api/chat/dms` opens (or returns) the 1:1 DM between the caller
  and `recipient_user_id`. Pair uniqueness is coordinated by
  `chat_v2.dm_pairs` (PK `pair_key = "<user_low>:<user_high>"`, the old
  Worker `canonicalDmPairKey`) inside ONE PG transaction (D11) —
  A↔B always resolves to the same `channel_id`.

  Flow (old Worker `dms.ts` + `UserDirectory.openDm` +
  `DMDirectory.getOrCreateDm` + `ChatChannel.createDm` collapsed into one
  D11 transaction on the target channel's writer, D13):

  1. caller-level validation: `recipient_user_id` required and ≠ caller
     (`422 INVALID_DM_TARGET`);
  2. idempotency pre-check (`409 IDEMPOTENCY_CONFLICT` when the same
     `Idempotency-Key` is reused with a different recipient);
  3. recipient validation: UUID-shaped (`422 INVALID_DM_TARGET`), exists
     in `public.users` (`404 DM_TARGET_NOT_FOUND`);
  4. `dm_pairs` get-or-create: an existing pair wins (a concurrent open
     loses its pre-minted channel id via the `pair_key` unique
     constraint); a fresh pair creates the `dm_pairs` row + the DM
     channel (`kind: "dm"`, `visibility: "private"`, `title: ""`, both
     members, `member_count: 2`, `membership_version: 1`) + the old
     Worker's `this.created` bookkeeping event (the old Worker's replay
     filters it out of the wire, and `LiliumChat.Timeline` does the same)
     + the `this.create_dm` audit row;
  5. response = full DM-aware `ChannelSummary` (dm_peer UserSummary,
     peer-resolved `title` / `avatar_url`, `role: "member"`) +
     `membership: {role, joined_at}` — recorded for idempotent replay.

  ## Conformance deltas vs the old Worker (contract v2.31 wins)

  * The old Worker's cross-DO coordination (idempotency row `creating` →
    DM Directory → ChatChannel → `completeOpenDm`) is one D11
    transaction; there is no `resume` state to recover.
  * A healed missing / `left` participant row is re-inserted (self-heal);
    the old Worker 503s (`missing joined_at for opener`) on that archive
    inconsistency.
  * The fresh-DM `channel_joined` user hints (D8) replace the old
    Worker's `user_directory` outbox join notifications.
  * `last_message_preview` keeps the old Worker `getSummary` raw text
    (the v2 read-path "name: text" projection is a #5/#6 delta that does
    not apply to this endpoint).
  """

  alias LiliumChat.{
    CanonicalJSON,
    Channel,
    ChannelEvents,
    Errors,
    Idempotency,
    Ids,
    Profiles,
    Projections,
    Query,
    Repo
  }

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  # -------------------------------------------------------------- entry point

  @doc """
  Open (or get) the caller's DM with `recipient_user_id`
  (`POST /api/chat/dms`, §5.2c). `body` is the parsed JSON body.

  Returns `{:ok, response}` (a fresh commit or an idempotent replay) or
  `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def open(user_id, key, body) do
    recipient = if is_map(body), do: body["recipient_user_id"], else: nil

    # Route-level validation (old Worker `dms.ts` parity).
    case recipient do
      nil ->
        {:error, Errors.new("INVALID_DM_TARGET", "recipient_user_id required")}

      "" ->
        {:error, Errors.new("INVALID_DM_TARGET", "recipient_user_id required")}

      _ ->
        if recipient == user_id do
          {:error, Errors.new("INVALID_DM_TARGET", "cannot open DM with yourself")}
        else
          do_open(user_id, key, recipient)
        end
    end
  end

  defp do_open(user_id, key, recipient) do
    request_hash = CanonicalJSON.encode_and_sha256([{"recipient_user_id", recipient}])

    case Idempotency.check("user", user_id, "dm.open", key, request_hash) do
      {:cached, response} ->
        {:ok, response}

      {:conflict, api_error} ->
        {:error, api_error}

      :missing ->
        # The routing channel: the existing pair's channel (if any) or a
        # pre-minted id for the fresh case (D13: the writer must own the
        # channel that may receive the `this.created` event). A concurrent
        # open resolves via the `dm_pairs` unique constraint inside the txn.
        {user_low, user_high} = canonical_pair(user_id, recipient)
        pair_key = "#{user_low}:#{user_high}"
        channel_id = pair_channel_id(pair_key) || Ids.uuidv7()

        Channel.open_dm(channel_id, %{
          user_id: user_id,
          command_id: key,
          recipient_user_id: recipient
        })
    end
  end

  # ---------------------------------------------------------- writer op (D13)

  @doc """
  The `dm.open` write on the target channel's writer (D13). `input` is
  `%{user_id: binary, command_id: binary, recipient_user_id: binary}`.
  """
  def open_dm(channel_id, seq, input) do
    user_id = input[:user_id]
    command_id = input[:command_id]
    recipient = input[:recipient_user_id]

    request_hash = CanonicalJSON.encode_and_sha256([{"recipient_user_id", recipient}])

    case Idempotency.run_writer_operation(
           "user",
           user_id,
           "dm.open",
           command_id,
           request_hash,
           fn -> do_open_dm(channel_id, seq, user_id, recipient) end
         ) do
      {:ok, %{kind: :opened, seq: new_seq} = payload} ->
        {Map.delete(payload, :seq), new_seq}

      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :cached, response: response}, seq}

      {:error, api_error} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # ------------------------------------------------------------------ in-txn

  defp do_open_dm(channel_id, seq, user_id, recipient) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    validate_recipient!(user_id, recipient)

    {user_low, user_high} = canonical_pair(user_id, recipient)
    pair_key = "#{user_low}:#{user_high}"

    case pair_channel_id(pair_key) do
      nil ->
        # Fresh pair: claim it (the unique constraint arbitrates a
        # concurrent open — the loser falls through to the existing path).
        inserted =
          Repo.query!(
            "INSERT INTO chat_v2.dm_pairs " <>
              "(pair_key, user_low, user_high, channel_id, created_by, status, created_at, updated_at) " <>
              "VALUES ($1, $2, $3, $4, $5, 'active', $6, $6) " <>
              "ON CONFLICT (pair_key) DO NOTHING",
            [pair_key, user_low, user_high, channel_id, user_id, now],
            type: true
          )

        case inserted.num_rows do
          1 ->
            fresh_dm(channel_id, seq, user_id, recipient, now, now_ms)

          0 ->
            # A concurrent open claimed the pair first: use ITS channel
            # (the pre-minted id is discarded — it has no rows).
            existing_dm(pair_channel_id(pair_key), seq, user_id, recipient, now)
        end

      pair_channel_id ->
        # Get-or-heal: the pair (and normally the channel) pre-exists.
        # The writer's `channel_id` equals `pair_channel_id` unless the
        # pair appeared after the pre-read, in which case the channel
        # already exists and no event is written here.
        existing_dm(pair_channel_id, seq, user_id, recipient, now)
    end
  end

  # The pair is new AND we own it: create the DM channel + both members +
  # the `this.created` bookkeeping event + the audit row (old Worker
  # `createDm` parity, minus the outbox / archive rows).
  defp fresh_dm(channel_id, seq, user_id, recipient, now, now_ms) do
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    Repo.query!(
      "INSERT INTO chat_v2.channels " <>
        "(channel_id, kind, visibility, title, topic, avatar_url, status, created_by, " <>
        " created_at, updated_at, member_count, membership_version) " <>
        "VALUES ($1, 'dm', 'private', '', NULL, NULL, 'active', $2, $3, $3, 2, 1)",
      [channel_id, user_id, now],
      type: true
    )

    ChannelEvents.upsert_active_member(channel_id, user_id, now)
    ChannelEvents.upsert_active_member(channel_id, recipient, now)

    Repo.query!(
      "INSERT INTO chat_v2.audit_logs " <>
        "(audit_id, actor_kind, actor_id, action, target_type, target_id, before_json, after_json, reason, request_id, created_at) " <>
        "VALUES ($1, 'user', $2, 'this.create_dm', 'channel', $3, NULL, $4, NULL, NULL, $5)",
      [
        "#{channel_id}:create-dm:#{Projections.format_ts(now)}",
        user_id,
        channel_id,
        %{"channel_id" => channel_id, "kind" => "dm", "user_a" => user_id, "user_b" => recipient},
        now
      ],
      type: true
    )

    payload = %{
      "channel" => %{
        "channel_id" => channel_id,
        "kind" => "dm",
        "visibility" => "private",
        "title" => ""
      },
      "actor_kind" => "user",
      "actor_id" => user_id
    }

    ChannelEvents.insert_event(event_id, "this.created", channel_id, payload, 1, now)

    %{
      kind: :opened,
      response:
        dm_response(channel_id, user_id, recipient,
          joined_at: Projections.format_ts(now),
          last_event_id: event_id
        ),
      # The old Worker does NOT live-fanout `this.created` (it is a
      # bookkeeping row its replay filters); both users learn of the new
      # DM from the `channel_joined` hints (D8).
      event_frames: [],
      user_hints: [
        {user_id, "channel_joined"},
        {recipient, "channel_joined"}
      ],
      seq: new_seq
    }
  end

  # The pair (and usually the channel) pre-exists: heal missing / left
  # participant rows when needed, then re-inflate the summary.
  defp existing_dm(channel_id, seq, user_id, recipient, now) do
    shell? =
      if load_meta(channel_id) == nil do
        # Archive inconsistency (pair row without channel row): create the
        # channel shell (no `this.created` — the old Worker's `createDm`
        # writes one only for channels IT creates).
        create_dm_shell(channel_id, user_id, now)

        true
      else
        false
      end

    changes = [
      {user_id, ChannelEvents.upsert_active_member(channel_id, user_id, now)},
      {recipient, ChannelEvents.upsert_active_member(channel_id, recipient, now)}
    ]

    healed_count = Enum.count(changes, fn {_uid, changed?} -> changed? end)

    # A fresh shell already counts both participants; heals on an
    # existing channel bump the count / mv per healed member.
    unless shell? or healed_count == 0 do
      Repo.query!(
        "UPDATE chat_v2.channels " <>
          "SET membership_version = membership_version + $2, member_count = member_count + $2, " <>
          "updated_at = $3 WHERE channel_id = $1",
        [channel_id, healed_count, now],
        type: true
      )
    end

    member = member_row(channel_id, user_id)
    joined_at = Projections.format_ts(member["joined_at"])

    # A pure get has no membership change — hints only when we healed.
    user_hints =
      Enum.filter(changes, fn {_uid, changed?} -> changed? end)
      |> Enum.map(fn {uid, _} -> {uid, "channel_joined"} end)

    %{
      kind: :opened,
      response:
        dm_response(
          channel_id,
          user_id,
          recipient,
          joined_at: joined_at,
          last_event_id: last_event_id(channel_id)
        ),
      event_frames: [],
      user_hints: user_hints,
      seq: seq
    }
  end

  defp create_dm_shell(channel_id, created_by, now) do
    Repo.query!(
      "INSERT INTO chat_v2.channels " <>
        "(channel_id, kind, visibility, title, topic, avatar_url, status, created_by, " <>
        " created_at, updated_at, member_count, membership_version) " <>
        "VALUES ($1, 'dm', 'private', '', NULL, NULL, 'active', $2, $3, $3, 2, 1)",
      [channel_id, created_by, now],
      type: true
    )
  end

  # ------------------------------------------------------------- validation

  # Old Worker `openDm` parity: UUID-shaped + ≠ caller + exists in
  # `public.users`.
  defp validate_recipient!(user_id, recipient) do
    unless is_binary(recipient) and Regex.match?(@uuid_re, recipient) do
      raise Errors.new("INVALID_DM_TARGET", "invalid recipient_user_id")
    end

    if recipient == user_id do
      raise Errors.new("INVALID_DM_TARGET", "cannot open DM with yourself")
    end

    unless Map.has_key?(Profiles.resolve([recipient]), recipient) do
      raise Errors.new("DM_TARGET_NOT_FOUND", "recipient user not found")
    end
  end

  defp canonical_pair(a, b) do
    if a <= b do
      {a, b}
    else
      {b, a}
    end
  end

  # ---------------------------------------------------------------- response

  # Full DM-aware `ChannelSummary` (contract §5.2c: the response carries
  # the complete summary incl. `dm_peer`): peer-resolved `title` /
  # `avatar_url`, `role: "member"`, `unread_count: 0` (old Worker `openDm`
  # parity — it never computes unread on open), raw-text
  # `last_message_preview` (old Worker `getSummary` parity).
  defp dm_response(channel_id, opener, recipient,
         joined_at: joined_at,
         last_event_id: last_event_id
       ) do
    meta = load_meta(channel_id)
    {text, at} = last_message(channel_id)
    last_read = last_read_event_id(channel_id, opener)
    # The peer is, by definition, the OTHER participant — the recipient of
    # this `dm.open` — from the opener's point of view (A↔B symmetry: each
    # side's summary names the same counterparty).
    peer = recipient

    profiles = Profiles.resolve([opener, peer])
    peer_summary = Projections.user_summary(peer, profiles)

    summary = %{
      "channel_id" => channel_id,
      "kind" => "dm",
      "visibility" => meta["visibility"],
      "title" => peer_summary["display_name"],
      "topic" => nil,
      "avatar_url" => peer_summary["avatar_url"],
      "member_count" => meta["member_count"],
      "status" => meta["status"],
      "created_at" => Projections.format_ts(meta["created_at"]),
      "updated_at" => Projections.format_ts(meta["updated_at"]),
      "unread_count" => 0,
      "last_read_event_id" => last_read,
      "last_message_preview" => text,
      "last_message_at" => Projections.format_ts(at),
      "last_event_id" => last_event_id,
      "role" => "member",
      "dm_peer" => peer_summary
    }

    %{
      "channel" => summary,
      "membership" => %{"role" => "member", "joined_at" => joined_at}
    }
  end

  # ------------------------------------------------------------------ queries

  defp pair_channel_id(pair_key) do
    Query.rows(
      Repo.query("SELECT channel_id FROM chat_v2.dm_pairs WHERE pair_key = $1", [pair_key],
        type: true
      )
    )
    |> List.first()
    |> case do
      %{"channel_id" => channel_id} -> channel_id
      _ -> nil
    end
  end

  defp load_meta(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT channel_id, kind, visibility, title, topic, avatar_url, status, " <>
          "member_count, membership_version, created_at, updated_at " <>
          "FROM chat_v2.channels WHERE channel_id = $1",
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

  defp last_event_id(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT event_id FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id DESC LIMIT 1",
        [channel_id],
        type: true
      )
    )
    |> List.first()
    |> case do
      %{"event_id" => event_id} -> event_id
      _ -> nil
    end
  end

  # Old Worker `getSummary` parity: newest non-deleted / non-recalled
  # message (raw text, no "name: " prefix).
  defp last_message(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT text, created_at FROM chat_v2.messages " <>
          "WHERE channel_id = $1 AND status NOT IN ('deleted', 'recalled') " <>
          "ORDER BY created_at DESC, message_id DESC LIMIT 1",
        [channel_id],
        type: true
      )
    )
    |> List.first()
    |> case do
      %{"text" => text, "created_at" => at} -> {text, at}
      _ -> {nil, nil}
    end
  end

  defp last_read_event_id(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT last_read_event_id FROM chat_v2.read_state WHERE channel_id = $1 AND user_id = $2",
        [channel_id, user_id],
        type: true
      )
    )
    |> List.first()
    |> case do
      %{"last_read_event_id" => value} -> value
      _ -> nil
    end
  end
end
