defmodule LiliumChat.MemberCommands do
  @moduledoc """
  Channel member-management write path (contract §7.2 / §7.3 / §7.4 / §7.5,
  issue #12): `members.add`, `members.role`, `members.remove`,
  `channel.owner_transfer`.

  Each command follows the `LiliumChat.ChannelLifecycle` pattern: payload
  normalization (old Worker route-layer defaults), a pre-txn kind gate, a
  cheap idempotency pre-check, then ONE PG transaction (D11) that re-checks
  idempotency, gates the channel + roles, writes the business rows + timeline
  events + the contract §10.4 `system.notice`, and records the committed HTTP
  response in the single `idempotency` table (D10).

  Event ids are allocated from the per-channel monotonic `seq` (D13). The
  caller — the per-channel writer `LiliumChat.Channel` — owns the `seq`,
  broadcasts the returned `event_frames` on `channel:<id>` after commit, and
  delivers the returned `user_hints` (`my_channels_changed`, contract §10.5)
  on the affected users' `user:<uid>` topics.

  ## membership_version schedule (old Worker parity)

  * add (fresh insert or reactivation of a `left` row): +1, one
    `member.joined` event;
  * role change: +1, one `member.role_updated` event;
  * remove / self-leave: +1, one `member.left` event;
  * owner transfer: +2 in ONE transaction (two `member.role_updated` events at
    mv+1 / mv+2) — the contract §7.5 single-owner invariant holds inside the
    transaction; no zero-owner / multi-owner intermediate state is visible.

  ## Conformance deltas vs the old Worker (contract v2.31 wins)

  * The member ops emit `system.notice` events (notice_kind
    `member.joined` / `member.left` / `member.role_updated`) the old Worker
    does not — the same delta as #11's lifecycle notices (contract §10.4:
    成员加入/离开/角色变更 get a notice in the same transaction). Owner
    transfer carries two notices, one per `member.role_updated` event.
  * `channel_members.status` is the v2 SoT column: both self-leave and
    owner-removal write `status = 'left'` (the old Worker tracked
    `left_at` only). The contract §7.1b `removed` value is unreachable in
    v2's `active | left` status domain — a documented wire delta.
  * `my_channels_changed` hints (D8, old Worker parity): add →
    `channel_joined` to the added user, remove → `channel_left` to the
    leaving user, role change / owner transfer → none (only the old
    Worker's user-directory join/leave outbox rows triggered live resync).
  * Route-layer parity: a missing `user_id` / `target_user_id` /
    `previous_owner_role` normalizes to `""` (old Worker `?? ""`), and a
    missing `role` on add normalizes to `"member"` (`?? "member"`); the
    canonical request hash covers the normalized values.
  """

  alias LiliumChat.{
    CanonicalJSON,
    Errors,
    Idempotency,
    Ids,
    Profiles,
    Projections,
    Query,
    Repo
  }

  # --------------------------------------------------------------------------
  # members.add (§7.2)
  # --------------------------------------------------------------------------

  @doc """
  Add a member (`POST /api/chat/channels/{channel_id}/members`). `input` is
  `%{user_id: binary, command_id: binary, payload: map}` (the actor, the
  `Idempotency-Key` and the JSON body; the target user comes from the body's
  `user_id`). Returns `{result, new_seq}`:

    * `%{kind: :added, response: map, event_frames: [map],
      user_hints: [{user_id, reason}]}`
    * `%{kind: :cached, response: map}`
    * `%{kind: :error, error: %Errors.ApiError{}}`
  """
  def add(channel_id, seq, input) do
    user_id = input.user_id
    payload = input.payload || %{}
    command_id = input.command_id

    with {:ok, meta0} <- load_meta(channel_id),
         :ok <- kind_gate(meta0),
         {:ok, parsed} <- parse_add(payload) do
      request_hash = add_request_hash(parsed)

      case Idempotency.check("user", user_id, "members.add", command_id, request_hash) do
        {:cached, response} -> {%{kind: :cached, response: response}, seq}
        _ -> do_add(channel_id, user_id, seq, command_id, parsed, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} -> {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # members.role (§7.3)
  # --------------------------------------------------------------------------

  @doc """
  Change a member's role (`PATCH /api/chat/channels/{channel_id}/members/{user_id}`).
  `input` is `%{user_id: binary, command_id: binary, target_user_id: binary,
  payload: map}` (the target comes from the path). Returns
  `{result, new_seq}` (`kind: :role_updated` / `:cached` / `:error`).
  """
  def update_role(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id
    target = input.target_user_id
    payload = input.payload || %{}
    role = if is_map(payload), do: payload["role"], else: nil

    with {:ok, meta0} <- load_meta(channel_id),
         :ok <- kind_gate(meta0) do
      request_hash = role_request_hash(target, role)

      case Idempotency.check("user", user_id, "members.role", command_id, request_hash) do
        {:cached, response} -> {%{kind: :cached, response: response}, seq}
        _ -> do_update_role(channel_id, user_id, seq, command_id, target, role, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} -> {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # members.remove (§7.4)
  # --------------------------------------------------------------------------

  @doc """
  Remove a member or self-leave (`DELETE /api/chat/channels/{channel_id}/members/{user_id}`).
  `input` is `%{user_id: binary, command_id: binary, target_user_id: binary}`
  (the target comes from the path). Returns `{result, new_seq}`
  (`kind: :removed` / `:cached` / `:error`).
  """
  def remove(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id
    target = input.target_user_id

    with {:ok, meta0} <- load_meta(channel_id),
         :ok <- kind_gate(meta0) do
      request_hash = remove_request_hash(target)

      case Idempotency.check("user", user_id, "members.remove", command_id, request_hash) do
        {:cached, response} -> {%{kind: :cached, response: response}, seq}
        _ -> do_remove(channel_id, user_id, seq, command_id, target, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} -> {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # channel.owner_transfer (§7.5)
  # --------------------------------------------------------------------------

  @doc """
  Atomically transfer ownership (`POST /api/chat/channels/{channel_id}/owner-transfer`).
  `input` is `%{user_id: binary, command_id: binary, payload: map}` (the target
  user comes from the body's `target_user_id`, the new role of the old owner
  from `previous_owner_role`). One transaction writes both role changes + the
  `channels.created_by` hand-off (contract §7.5: no zero-owner / multi-owner
  intermediate state). Returns `{result, new_seq}`
  (`kind: :transferred` / `:cached` / `:error`).
  """
  def transfer_owner(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id
    payload = input.payload || %{}

    target = if is_map(payload), do: payload["target_user_id"] || "", else: ""
    prev_role = if is_map(payload), do: payload["previous_owner_role"] || "", else: ""

    with {:ok, meta0} <- load_meta(channel_id),
         :ok <- kind_gate(meta0) do
      request_hash = transfer_request_hash(target, prev_role)

      case Idempotency.check(
             "user",
             user_id,
             "channel.owner_transfer",
             command_id,
             request_hash
           ) do
        {:cached, response} ->
          {%{kind: :cached, response: response}, seq}

        _ ->
          do_transfer_owner(channel_id, user_id, seq, command_id, target, prev_role, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} -> {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # add
  # --------------------------------------------------------------------------

  # Old Worker route parity: `body.user_id ?? ""`, `body.role ?? "member"`.
  # A non-map body behaves like an empty object (Hono `c.req.json().catch(() => ({}))`).
  defp parse_add(payload) when is_map(payload) do
    {:ok, %{target: payload["user_id"] || "", role: payload["role"] || "member"}}
  end

  defp parse_add(_payload), do: {:ok, %{target: "", role: "member"}}

  # Old Worker: JSON.stringify({ user_id: targetUserId, role }) over the
  # normalized values, fixed key order.
  defp add_request_hash(parsed) do
    CanonicalJSON.encode_and_sha256([
      {"user_id", parsed[:target]},
      {"role", parsed[:role]}
    ])
  end

  defp do_add(channel_id, user_id, seq, command_id, parsed, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    profiles = Profiles.resolve(Enum.uniq([user_id, parsed[:target]]))

    result =
      run_idempotent_txn(user_id, "members.add", command_id, request_hash, fn ->
        do_add_inner(
          channel_id,
          user_id,
          seq,
          command_id,
          parsed,
          request_hash,
          profiles,
          now,
          now_ms
        )
      end)

    finalize(result, seq)
  end

  defp do_add_inner(
         channel_id,
         user_id,
         seq,
         command_id,
         parsed,
         request_hash,
         profiles,
         now,
         now_ms
       ) do
    target = parsed[:target]
    role = parsed[:role]

    case load_meta_full(channel_id) do
      nil ->
        Repo.rollback(%{
          kind: :error,
          error: Errors.new("CHANNEL_NOT_FOUND", "channel not found")
        })

      meta ->
        caller_role = active_role(channel_id, user_id)

        cond do
          meta["status"] == "dissolved" ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
            })

          caller_role not in ["owner", "admin"] ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("FORBIDDEN", "not authorized to add members")
            })

          role not in ["member", "admin"] ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("INVALID_MESSAGE", "role must be member or admin")
            })

          target == user_id ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("INVALID_MESSAGE", "cannot add self")
            })

          target == meta["created_by"] ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("INVALID_MESSAGE", "owner is fixed; cannot add the owner")
            })

          true ->
            apply_add(
              channel_id,
              user_id,
              seq,
              command_id,
              parsed,
              request_hash,
              profiles,
              meta,
              now,
              now_ms
            )
        end
    end
  end

  defp apply_add(
         channel_id,
         user_id,
         seq,
         command_id,
         parsed,
         request_hash,
         profiles,
         meta,
         now,
         now_ms
       ) do
    target = parsed[:target]
    role = parsed[:role]
    existing = member_row(channel_id, target)

    case existing do
      %{"status" => "active"} ->
        # Old Worker P0-5: an already-active target must NOT change role via
        # add (that's PATCH); a same-role re-add is a no-op whose response is
        # recorded for THIS key (so a later retry replays it).
        if existing["role"] != role do
          Repo.rollback(%{
            kind: :error,
            error:
              Errors.new(
                "INVALID_MESSAGE",
                "member already active; use PATCH /members/{user_id} to change role"
              )
          })
        else
          # Old Worker wire parity: the no-op re-add answers the SAME
          # `{member: ...}` envelope — minus `joined_at`.
          response = %{"member" => member_response(channel_id, target, existing["role"])}

          Idempotency.write_completed(
            "user",
            user_id,
            "members.add",
            command_id,
            request_hash,
            response
          )

          %{kind: :added, response: response, event_frames: [], user_hints: [], seq: seq}
        end

      nil ->
        commit_add(
          channel_id,
          user_id,
          seq,
          command_id,
          target,
          role,
          request_hash,
          profiles,
          meta,
          now,
          now_ms,
          false
        )

      %{"status" => "left"} ->
        commit_add(
          channel_id,
          user_id,
          seq,
          command_id,
          target,
          role,
          request_hash,
          profiles,
          meta,
          now,
          now_ms,
          true
        )
    end
  end

  # Fresh insert OR reactivation of a `left` row: mv+1, count+1 (either
  # way — old Worker parity), one `member.joined` + the §10.4 notice,
  # `channel_joined` hint to the added user.
  defp commit_add(
         channel_id,
         user_id,
         seq,
         command_id,
         target,
         role,
         request_hash,
         profiles,
         meta,
         now,
         now_ms,
         reactivate?
       ) do
    mv = meta["membership_version"] + 1
    joined_at = Projections.format_ts(now)

    if reactivate? do
      Repo.query!(
        "UPDATE chat_v2.channel_members " <>
          "SET role = $3, joined_at = $4, left_at = NULL, status = 'active' " <>
          "WHERE channel_id = $1 AND user_id = $2",
        [channel_id, target, role, now],
        type: true
      )
    else
      insert_member(channel_id, target, role, now)
    end

    Repo.query!(
      "UPDATE chat_v2.channels " <>
        "SET membership_version = $2, member_count = $3, updated_at = $4 " <>
        "WHERE channel_id = $1",
      [channel_id, mv, meta["member_count"] + 1, now],
      type: true
    )

    {joined_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
    {notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)

    joined_payload = %{
      "channel_id" => channel_id,
      "user_id" => target,
      "role" => role,
      "membership_version" => mv,
      "actor_kind" => "user",
      "actor_id" => user_id,
      "join_source" => "admin_add",
      "inviter_user_id" => nil
    }

    insert_event(joined_id, "member.joined", channel_id, joined_payload, mv, now)

    notice_payload = notice_payload("member.joined", user_id, target)
    insert_notice_event(notice_id, channel_id, user_id, notice_payload, mv, now)

    frames = [
      event_frame(joined_id, "member.joined", channel_id, now, joined_payload, mv, profiles),
      notice_frame(notice_id, channel_id, now, notice_payload, mv, profiles)
    ]

    response = %{"member" => member_response(channel_id, target, role, joined_at)}

    Idempotency.write_completed(
      "user",
      user_id,
      "members.add",
      command_id,
      request_hash,
      response
    )

    %{
      kind: :added,
      response: response,
      event_frames: frames,
      user_hints: [{target, "channel_joined"}],
      seq: s2
    }
  end

  defp member_response(channel_id, user_id, role),
    do: %{"channel_id" => channel_id, "user_id" => user_id, "role" => role}

  defp member_response(channel_id, user_id, role, joined_at),
    do: Map.put(member_response(channel_id, user_id, role), "joined_at", joined_at)

  # --------------------------------------------------------------------------
  # role
  # --------------------------------------------------------------------------

  # Old Worker: JSON.stringify({ user_id: targetUserId, role }) — note the
  # PATCH body's `role` is NOT defaulted (a missing role hashes as "" and
  # 422s in the gate, matching the old Worker route `body.role ?? ""`).
  defp role_request_hash(target, role) do
    CanonicalJSON.encode_and_sha256([
      {"user_id", target},
      {"role", role || ""}
    ])
  end

  defp do_update_role(channel_id, user_id, seq, command_id, target, role, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    profiles = Profiles.resolve(Enum.uniq([user_id, target]))

    result =
      run_idempotent_txn(user_id, "members.role", command_id, request_hash, fn ->
        do_update_role_inner(
          channel_id,
          user_id,
          seq,
          command_id,
          target,
          role,
          request_hash,
          profiles,
          now,
          now_ms
        )
      end)

    finalize(result, seq)
  end

  defp do_update_role_inner(
         channel_id,
         user_id,
         seq,
         command_id,
         target,
         role,
         request_hash,
         profiles,
         now,
         now_ms
       ) do
    case load_meta_full(channel_id) do
      nil ->
        Repo.rollback(%{
          kind: :error,
          error: Errors.new("CHANNEL_NOT_FOUND", "channel not found")
        })

      meta ->
        caller_role = active_role(channel_id, user_id)

        cond do
          meta["status"] == "dissolved" ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
            })

          caller_role != "owner" ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("FORBIDDEN", "only owner may change roles")
            })

          role not in ["member", "admin"] ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("INVALID_MESSAGE", "role must be member or admin")
            })

          true ->
            case member_row(channel_id, target) do
              nil ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("MEMBER_NOT_FOUND", "target not an active member")
                })

              %{"status" => "left"} ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("MEMBER_NOT_FOUND", "target not an active member")
                })

              %{"status" => "active"} = target_row ->
                cond do
                  target == meta["created_by"] ->
                    Repo.rollback(%{
                      kind: :error,
                      error:
                        Errors.new(
                          "INVALID_MESSAGE",
                          "cannot change the owner's role (owner is fixed)"
                        )
                    })

                  target == user_id ->
                    Repo.rollback(%{
                      kind: :error,
                      error: Errors.new("INVALID_MESSAGE", "owner cannot change own role")
                    })

                  true ->
                    commit_role_update(
                      channel_id,
                      user_id,
                      seq,
                      command_id,
                      target,
                      role,
                      request_hash,
                      profiles,
                      meta,
                      target_row["role"],
                      now,
                      now_ms
                    )
                end
            end
        end
    end
  end

  defp commit_role_update(
         channel_id,
         user_id,
         seq,
         command_id,
         target,
         role,
         request_hash,
         profiles,
         meta,
         before_role,
         now,
         now_ms
       ) do
    mv = meta["membership_version"] + 1

    Repo.query!(
      "UPDATE chat_v2.channel_members SET role = $3 WHERE channel_id = $1 AND user_id = $2",
      [channel_id, target, role],
      type: true
    )

    Repo.query!(
      "UPDATE chat_v2.channels SET membership_version = $2, updated_at = $3 WHERE channel_id = $1",
      [channel_id, mv, now],
      type: true
    )

    {updated_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
    {notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)

    updated_payload = %{
      "channel_id" => channel_id,
      "user_id" => target,
      "before_role" => before_role,
      "after_role" => role,
      "membership_version" => mv,
      "actor_kind" => "user",
      "actor_id" => user_id
    }

    insert_event(updated_id, "member.role_updated", channel_id, updated_payload, mv, now)

    notice_payload = notice_payload("member.role_updated", user_id, target)
    insert_notice_event(notice_id, channel_id, user_id, notice_payload, mv, now)

    frames = [
      event_frame(
        updated_id,
        "member.role_updated",
        channel_id,
        now,
        updated_payload,
        mv,
        profiles
      ),
      notice_frame(notice_id, channel_id, now, notice_payload, mv, profiles)
    ]

    response = %{"member" => member_response(channel_id, target, role)}

    Idempotency.write_completed(
      "user",
      user_id,
      "members.role",
      command_id,
      request_hash,
      response
    )

    %{
      kind: :role_updated,
      response: response,
      event_frames: frames,
      # D8: role change alone never triggers my_channels_changed.
      user_hints: [],
      seq: s2
    }
  end

  # --------------------------------------------------------------------------
  # remove
  # --------------------------------------------------------------------------

  # Old Worker: JSON.stringify({ user_id: targetUserId }).
  defp remove_request_hash(target) do
    CanonicalJSON.encode_and_sha256([
      {"user_id", target}
    ])
  end

  defp do_remove(channel_id, user_id, seq, command_id, target, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    profiles = Profiles.resolve(Enum.uniq([user_id, target]))

    result =
      run_idempotent_txn(user_id, "members.remove", command_id, request_hash, fn ->
        do_remove_inner(
          channel_id,
          user_id,
          seq,
          command_id,
          target,
          request_hash,
          profiles,
          now,
          now_ms
        )
      end)

    finalize(result, seq)
  end

  defp do_remove_inner(
         channel_id,
         user_id,
         seq,
         command_id,
         target,
         request_hash,
         profiles,
         now,
         now_ms
       ) do
    is_self = target == user_id

    case load_meta_full(channel_id) do
      nil ->
        Repo.rollback(%{
          kind: :error,
          error: Errors.new("CHANNEL_NOT_FOUND", "channel not found")
        })

      meta ->
        caller_role = active_role(channel_id, user_id)
        dissolved? = meta["status"] == "dissolved"

        # Old Worker gate chain (exact order): on a dissolved channel a
        # self-leave is allowed for ANYONE — including the owner (the
        # owner-must-dissolve-or-transfer rule applies to ACTIVE channels
        # only, per the old Worker's P1-6 comment); on an active channel
        # only the owner may remove others, and the owner cannot leave
        # without dissolving or transferring first.
        cond do
          dissolved? and not is_self ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
            })

          not dissolved? and not is_self and caller_role != "owner" ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("FORBIDDEN", "only owner may remove others")
            })

          not dissolved? and is_self and target == meta["created_by"] ->
            Repo.rollback(%{
              kind: :error,
              error:
                Errors.new(
                  "INVALID_MESSAGE",
                  "owner cannot leave; dissolve the channel or transfer ownership in a future phase"
                )
            })

          true ->
            case member_row(channel_id, target) do
              nil ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("MEMBER_NOT_FOUND", "target not an active member")
                })

              %{"status" => "left"} ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("MEMBER_NOT_FOUND", "target not an active member")
                })

              %{"status" => "active"} = target_row ->
                commit_remove(
                  channel_id,
                  user_id,
                  seq,
                  command_id,
                  target,
                  request_hash,
                  profiles,
                  meta,
                  target_row["role"],
                  is_self,
                  now,
                  now_ms
                )
            end
        end
    end
  end

  defp commit_remove(
         channel_id,
         user_id,
         seq,
         command_id,
         target,
         request_hash,
         profiles,
         meta,
         target_role,
         is_self,
         now,
         now_ms
       ) do
    mv = meta["membership_version"] + 1
    leave_source = if is_self, do: "self", else: "removed"

    Repo.query!(
      "UPDATE chat_v2.channel_members SET left_at = $3, status = 'left' " <>
        "WHERE channel_id = $1 AND user_id = $2",
      [channel_id, target, now],
      type: true
    )

    Repo.query!(
      "UPDATE chat_v2.channels " <>
        "SET membership_version = $2, member_count = $3, updated_at = $4 " <>
        "WHERE channel_id = $1",
      [channel_id, mv, max(0, meta["member_count"] - 1), now],
      type: true
    )

    {left_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
    {notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)

    left_payload = %{
      "channel_id" => channel_id,
      "user_id" => target,
      "role" => target_role,
      "membership_version" => mv,
      "actor_kind" => "user",
      "actor_id" => user_id,
      "leave_source" => leave_source
    }

    insert_event(left_id, "member.left", channel_id, left_payload, mv, now)

    notice_payload = notice_payload("member.left", user_id, target)
    insert_notice_event(notice_id, channel_id, user_id, notice_payload, mv, now)

    frames = [
      event_frame(left_id, "member.left", channel_id, now, left_payload, mv, profiles),
      notice_frame(notice_id, channel_id, now, notice_payload, mv, profiles)
    ]

    response = %{
      "channel_id" => channel_id,
      "user_id" => target,
      "removed" => true
    }

    Idempotency.write_completed(
      "user",
      user_id,
      "members.remove",
      command_id,
      request_hash,
      response
    )

    %{
      kind: :removed,
      response: response,
      event_frames: frames,
      user_hints: [{target, "channel_left"}],
      seq: s2
    }
  end

  # --------------------------------------------------------------------------
  # owner transfer
  # --------------------------------------------------------------------------

  # Old Worker: JSON.stringify({ target_user_id, previous_owner_role }) over
  # the normalized values, fixed key order.
  defp transfer_request_hash(target, prev_role) do
    CanonicalJSON.encode_and_sha256([
      {"target_user_id", target},
      {"previous_owner_role", prev_role}
    ])
  end

  defp do_transfer_owner(channel_id, user_id, seq, command_id, target, prev_role, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    profiles = Profiles.resolve(Enum.uniq([user_id, target]))

    result =
      run_idempotent_txn(user_id, "channel.owner_transfer", command_id, request_hash, fn ->
        do_transfer_owner_inner(
          channel_id,
          user_id,
          seq,
          command_id,
          target,
          prev_role,
          request_hash,
          profiles,
          now,
          now_ms
        )
      end)

    finalize(result, seq)
  end

  defp do_transfer_owner_inner(
         channel_id,
         user_id,
         seq,
         command_id,
         target,
         prev_role,
         request_hash,
         profiles,
         now,
         now_ms
       ) do
    case load_meta_full(channel_id) do
      nil ->
        Repo.rollback(%{
          kind: :error,
          error: Errors.new("CHANNEL_NOT_FOUND", "channel not found")
        })

      meta ->
        caller_role = active_role(channel_id, user_id)

        cond do
          meta["status"] == "dissolved" ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
            })

          caller_role != "owner" or meta["created_by"] != user_id ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("FORBIDDEN", "only owner may transfer ownership")
            })

          prev_role not in ["admin", "member"] ->
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("INVALID_MESSAGE", "previous_owner_role must be admin or member")
            })

          true ->
            case member_row(channel_id, target) do
              nil ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("MEMBER_NOT_FOUND", "target not an active member")
                })

              %{"status" => "left"} ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("MEMBER_NOT_FOUND", "target not an active member")
                })

              %{"status" => "active"} = target_row ->
                cond do
                  target_row["role"] not in ["member", "admin"] ->
                    Repo.rollback(%{
                      kind: :error,
                      error: Errors.new("INVALID_MEMBER_ROLE", "target must be member or admin")
                    })

                  target == meta["created_by"] ->
                    Repo.rollback(%{
                      kind: :error,
                      error:
                        Errors.new(
                          "INVALID_MEMBER_ROLE",
                          "cannot transfer ownership to current owner"
                        )
                    })

                  true ->
                    commit_transfer(
                      channel_id,
                      user_id,
                      seq,
                      command_id,
                      target,
                      prev_role,
                      request_hash,
                      profiles,
                      meta,
                      target_row["role"],
                      now,
                      now_ms
                    )
                end
            end
        end
    end
  end

  # Single transaction: old owner demoted, target promoted, created_by
  # handed over — no zero-owner / multi-owner intermediate state (§7.5).
  # mv bumps twice (mv+1 / mv+2), one `member.role_updated` + §10.4 notice
  # per role change.
  defp commit_transfer(
         channel_id,
         user_id,
         seq,
         command_id,
         target,
         prev_role,
         request_hash,
         profiles,
         meta,
         target_role,
         now,
         now_ms
       ) do
    first_mv = meta["membership_version"] + 1
    second_mv = meta["membership_version"] + 2

    Repo.query!(
      "UPDATE chat_v2.channel_members SET role = $3 WHERE channel_id = $1 AND user_id = $2",
      [channel_id, user_id, prev_role],
      type: true
    )

    Repo.query!(
      "UPDATE chat_v2.channel_members SET role = 'owner' WHERE channel_id = $1 AND user_id = $2",
      [channel_id, target],
      type: true
    )

    Repo.query!(
      "UPDATE chat_v2.channels " <>
        "SET created_by = $2, membership_version = $3, updated_at = $4 " <>
        "WHERE channel_id = $1",
      [channel_id, target, second_mv, now],
      type: true
    )

    {old_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
    {old_notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)
    {new_id, s3} = Ids.monotonic_uuidv7(s2, now_ms)
    {new_notice_id, s4} = Ids.monotonic_uuidv7(s3, now_ms)

    old_payload = %{
      "channel_id" => channel_id,
      "user_id" => user_id,
      "before_role" => "owner",
      "after_role" => prev_role,
      "membership_version" => first_mv,
      "actor_kind" => "user",
      "actor_id" => user_id
    }

    new_payload = %{
      "channel_id" => channel_id,
      "user_id" => target,
      "before_role" => target_role,
      "after_role" => "owner",
      "membership_version" => second_mv,
      "actor_kind" => "user",
      "actor_id" => user_id
    }

    insert_event(old_id, "member.role_updated", channel_id, old_payload, first_mv, now)

    old_notice_payload = notice_payload("member.role_updated", user_id, user_id)
    insert_notice_event(old_notice_id, channel_id, user_id, old_notice_payload, first_mv, now)

    insert_event(new_id, "member.role_updated", channel_id, new_payload, second_mv, now)

    new_notice_payload = notice_payload("member.role_updated", user_id, target)
    insert_notice_event(new_notice_id, channel_id, user_id, new_notice_payload, second_mv, now)

    frames = [
      event_frame(
        old_id,
        "member.role_updated",
        channel_id,
        now,
        old_payload,
        first_mv,
        profiles
      ),
      notice_frame(old_notice_id, channel_id, now, old_notice_payload, first_mv, profiles),
      event_frame(
        new_id,
        "member.role_updated",
        channel_id,
        now,
        new_payload,
        second_mv,
        profiles
      ),
      notice_frame(new_notice_id, channel_id, now, new_notice_payload, second_mv, profiles)
    ]

    response = %{
      "channel_id" => channel_id,
      "previous_owner" => %{"user_id" => user_id, "role" => prev_role},
      "new_owner" => %{"user_id" => target, "role" => "owner"}
    }

    Idempotency.write_completed(
      "user",
      user_id,
      "channel.owner_transfer",
      command_id,
      request_hash,
      response
    )

    %{
      kind: :transferred,
      response: response,
      event_frames: frames,
      # D8: the transfer is two role changes — no my_channels_changed.
      user_hints: [],
      seq: s4
    }
  end

  # --------------------------------------------------------------------------
  # idempotency (D10/D11) — same idiom as LiliumChat.ChannelLifecycle
  # --------------------------------------------------------------------------

  # The authoritative in-txn idempotency re-check. The pre-txn
  # `Idempotency.check` at each entry point is a cheap fast path; this
  # re-check runs inside the transaction so a concurrent duplicate cannot
  # slip past. `missing_fn` performs the business writes +
  # `Idempotency.write_completed` and returns the committed result
  # (kind: :added / :role_updated / :removed / :transferred, plus `seq` —
  # the writer's next seq).
  defp run_idempotent_txn(user_id, operation, command_id, request_hash, missing_fn) do
    Repo.transaction(fn ->
      case Idempotency.check("user", user_id, operation, command_id, request_hash) do
        {:conflict, api_error} ->
          Repo.rollback(%{kind: :error, error: api_error})

        {:cached, response} ->
          %{kind: :cached, response: response}

        :missing ->
          missing_fn.()
      end
    end)
  end

  # Normalize the transaction outcome to the tagged `{result, new_seq}` reply:
  # committed kinds carry the writer's next seq in the payload; a cached
  # replay or a rolled-back error keeps the writer's current seq.
  defp finalize(result, seq) do
    case result do
      {:ok, %{kind: kind, seq: new_seq} = payload}
      when kind in [:added, :role_updated, :removed, :transferred] ->
        {Map.delete(payload, :seq), new_seq}

      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :cached, response: response}, seq}

      {:error, %{kind: :error, error: api_error}} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # gates + rows
  # --------------------------------------------------------------------------

  defp load_meta(channel_id) do
    case Query.rows(
           Repo.query("SELECT kind FROM chat_v2.channels WHERE channel_id = $1", [channel_id])
         ) do
      [row] -> {:ok, row}
      [] -> {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found")}
    end
  end

  # Old Worker `assertChannelKindChannel` (pre-txn parity): only
  # `kind = "channel"` supports member management (DM channels do not).
  defp kind_gate(%{"kind" => kind}) do
    if kind == "channel" do
      :ok
    else
      {:error, Errors.new("UNSUPPORTED_CHANNEL_KIND", "operation not supported for DM channels")}
    end
  end

  defp load_meta_full(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT channel_id, kind, status, created_by, member_count, membership_version
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

  # The target member row in ANY status (the add state machine needs the
  # never-joined / left / active distinction, old Worker P0-5).
  defp member_row(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT role, status FROM chat_v2.channel_members WHERE channel_id = $1 AND user_id = $2",
        [channel_id, user_id]
      )
    )
    |> List.first()
  end

  defp insert_member(channel_id, user_id, role, now) do
    Repo.query!(
      "INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, left_at, status) " <>
        "VALUES ($1, $2, $3, $4, NULL, 'active')",
      [channel_id, user_id, role, now],
      type: true
    )
  end

  # --------------------------------------------------------------------------
  # events + frames (stored payloads keep reference fields; the wire payload
  # is re-projected with the shared Projections builders, identical to replay)
  # --------------------------------------------------------------------------

  # §10.4: the stored notice payload keeps stable refs (no UserSummaries);
  # the wire payload re-projects actor / target_user on output.
  defp notice_payload(kind, actor_user_id, target_user_id) do
    %{
      "notice_kind" => kind,
      "actor_user_id" => actor_user_id,
      "target_user_id" => target_user_id,
      "message_id" => nil,
      "channel_changes" => nil
    }
  end

  defp insert_event(event_id, event_type, channel_id, payload, mv, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id, payload,
        membership_version_at_event, occurred_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [
        event_id,
        event_type,
        channel_id,
        payload["actor_kind"],
        payload["actor_id"],
        payload,
        mv,
        now
      ],
      type: true
    )
  end

  defp insert_notice_event(event_id, channel_id, user_id, payload, mv, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id, payload,
        membership_version_at_event, occurred_at
      ) VALUES ($1, 'system.notice', $2, 'user', $3, $4, $5, $6)
      """,
      [event_id, channel_id, user_id, payload, mv, now],
      type: true
    )
  end

  defp event_frame(event_id, event_type, channel_id, now, stored_payload, mv, profiles) do
    Projections.build_event_frame(
      event_id,
      event_type,
      channel_id,
      now,
      Projections.resolve_actor(stored_payload, profiles)
    )
    |> Map.put("membership_version_at_event", mv)
  end

  defp notice_frame(event_id, channel_id, now, stored_payload, mv, profiles) do
    Projections.build_event_frame(
      event_id,
      "system.notice",
      channel_id,
      now,
      notice_wire(stored_payload, profiles)
    )
    |> Map.put("membership_version_at_event", mv)
  end

  # §10.4: the stored payload keeps stable refs; the wire payload re-projects
  # the resolved actor / target_user (all five keys always present).
  defp notice_wire(payload, profiles) do
    %{
      "notice_kind" => payload["notice_kind"],
      "actor" => Projections.user_summary(payload["actor_user_id"], profiles),
      "target_user" =>
        payload["target_user_id"] && Projections.user_summary(payload["target_user_id"], profiles),
      "message_id" => payload["message_id"],
      "channel_changes" => payload["channel_changes"]
    }
  end
end
