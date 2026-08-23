defmodule LiliumChat.ChannelLifecycle do
  @moduledoc """
  Channel lifecycle write path (contract §5.2b / §5.3 / §5.4, issue #11):
  `channel.create`, `channel.update`, `channel.dissolve`.

  Each command follows the `LiliumChat.MessageSend` pattern: payload
  validation, a cheap idempotency pre-check, then ONE PG transaction (D11)
  that re-checks idempotency, gates the channel, writes the business rows +
  timeline events + the contract §10.4 `system.notice`, and records the
  committed HTTP response in the single `idempotency` table (D10).

  Event ids are allocated from the per-channel monotonic `seq` (D13). The
  caller — the per-channel writer `LiliumChat.Channel` — owns the `seq`,
  broadcasts the returned `event_frames` on `channel:<id>` after commit,
  and delivers the returned `user_hints` (`my_channels_changed`,
  contract §10.5) on the affected users' `user:<uid>` topics.

  ## Conformance deltas vs the old Worker (contract v2.31 wins)

  * The create response carries `membership` (§5.2b) where the old
    Worker's HTTP response omitted it, and the lifecycle actions emit
    `system.notice` events the old Worker does not (same delta as
    `MessageMutate`'s delete notice).
  * `avatar_attachment_id` is accepted only as `null` until the
    attachments ticket lands (422 `INVALID_MESSAGE` otherwise); the old
    Worker resolves it against UserDirectory, which v2 does not have yet.
  * Value-level type validation is stricter than the old Worker (whose
    SQLite accepted whatever JSON arrived): a non-string `topic` /
    non-string `title` update value or a non-string, non-null `visibility`
    422s, and a missing `initial_members[].user_id` 422s (the old Worker
    crashed on the undefined INSERT).
  * The dissolve owner gate uses `channels.created_by` (old Worker parity);
    #12 (owner transfer) will revisit it.
  * `channels.membership_version` (D8) bumps only on join/leave/dissolve:
    create seeds it at `1 + len(initial_members)`, dissolve bumps by 1,
    update leaves it unchanged.
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

  @visibilities ~w(private public_unlisted public_listed)

  # --------------------------------------------------------------------------
  # channel.create (§5.2b)
  # --------------------------------------------------------------------------

  @doc """
  Create a channel. `channel_id` is minted by the caller (the writer entry
  point); `input` is `%{user_id: binary, command_id: binary, payload: map}`
  (the creator, the `Idempotency-Key` and the JSON body).

  Returns `{result, new_seq}`:

    * `%{kind: :created, response: map, event_frames: [map],
      user_hints: [{user_id, reason}]}`
    * `%{kind: :cached, response: map}`
    * `%{kind: :error, error: %Errors.ApiError{}}`
  """
  def create(channel_id, seq, input) do
    user_id = input.user_id
    payload = input.payload || %{}
    command_id = input.command_id

    case parse_create(payload, user_id) do
      {:ok, parsed} ->
        request_hash = create_request_hash(parsed)

        case Idempotency.check("user", user_id, "channel.create", command_id, request_hash) do
          {:cached, response} -> {%{kind: :cached, response: response}, seq}
          _ -> do_create(channel_id, user_id, seq, command_id, parsed, request_hash)
        end

      {:error, %Errors.ApiError{} = api_error} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # channel.update (§5.3)
  # --------------------------------------------------------------------------

  @doc """
  Update channel metadata (`title` / `topic` / `avatar_attachment_id` /
  `visibility`, presence-aware: omitted fields are unchanged, explicit
  `null` clears). `input` is `%{user_id: binary, command_id: binary,
  payload: map}`. Returns `{result, new_seq}` with the same tagged results
  as `create/3` (`kind: :updated` / `:cached` / `:error`).
  """
  def update(channel_id, seq, input) do
    user_id = input.user_id
    payload = input.payload || %{}
    command_id = input.command_id

    with {:ok, meta0} <- load_meta(channel_id),
         :ok <- kind_gate(meta0),
         {:ok, parsed} <- parse_update(payload) do
      request_hash = update_request_hash(parsed)

      case Idempotency.check("user", user_id, "channel.update", command_id, request_hash) do
        {:cached, response} -> {%{kind: :cached, response: response}, seq}
        _ -> do_update(channel_id, user_id, seq, command_id, parsed, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} -> {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # channel.dissolve (§5.4)
  # --------------------------------------------------------------------------

  @doc """
  Dissolve a channel (owner-only, `kind = "channel"`, tombstones the row).
  `input` is `%{user_id: binary, command_id: binary}`. Returns
  `{result, new_seq}` with the same tagged results as `create/3`
  (`kind: :dissolved` / `:cached` / `:error`).
  """
  def dissolve(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id
    # Dissolve carries no body: the old Worker hashes the empty object
    # (literal `"{}"`), so the hash is byte-identical across implementations.
    request_hash = CanonicalJSON.encode_and_sha256(%{})

    with {:ok, meta0} <- load_meta(channel_id),
         :ok <- kind_gate(meta0) do
      case Idempotency.check("user", user_id, "channel.dissolve", command_id, request_hash) do
        {:cached, response} -> {%{kind: :cached, response: response}, seq}
        _ -> do_dissolve(channel_id, user_id, seq, command_id, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} -> {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # create
  # --------------------------------------------------------------------------

  defp parse_create(payload, user_id) when is_map(payload) do
    raw_title = payload["title"]
    title = if is_binary(raw_title), do: String.trim(raw_title), else: nil

    # Old Worker: `topic ?? null` (SQLite accepted any JSON value); the v2
    # text column is typed, so a non-string 422s like the update path.
    raw_topic = payload["topic"]
    topic = if is_binary(raw_topic), do: raw_topic, else: nil

    avatar = payload["avatar_attachment_id"]

    # Old Worker parity: `visibility ?? "private"` (defaults only on
    # null/absent), then enum-checked — so a non-string like `5` 422s
    # "invalid visibility" rather than being silently coerced.
    visibility =
      case payload["visibility"] do
        nil -> "private"
        value -> value
      end

    cond do
      title in [nil, ""] ->
        {:error, Errors.new("INVALID_MESSAGE", "title is required")}

      not is_nil(avatar) ->
        {:error, Errors.new("INVALID_MESSAGE", "avatar_attachment_id not supported in Phase 3")}

      visibility not in @visibilities ->
        {:error, Errors.new("INVALID_MESSAGE", "invalid visibility")}

      not (is_nil(raw_topic) or is_binary(raw_topic)) ->
        {:error, Errors.new("INVALID_MESSAGE", "topic must be a string or null")}

      true ->
        case parse_initial_members(payload["initial_members"], user_id) do
          {:error, _} = err ->
            err

          {:ok, members} ->
            {:ok,
             %{
               raw_title: raw_title,
               title: title,
               topic: topic,
               visibility: visibility,
               initial_members: members
             }}
        end
    end
  end

  defp parse_create(_payload, _user_id),
    do: {:error, Errors.new("INVALID_MESSAGE", "payload must be an object")}

  defp parse_initial_members(raw, user_id) do
    list = if is_list(raw), do: raw, else: []

    case Enum.reduce_while(list, [], fn im, acc ->
           case parse_initial_member(im, user_id) do
             {:ok, item} -> {:cont, [item | acc]}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      items when is_list(items) -> {:ok, Enum.reverse(items)}
      {:error, _} = err -> err
    end
  end

  defp parse_initial_member(im, user_id) when is_map(im) do
    role = im["role"]
    member_id = im["user_id"]

    cond do
      role not in ["member", "admin"] ->
        {:error, Errors.new("INVALID_MESSAGE", "initial_members role must be member or admin")}

      not (is_binary(member_id) and member_id != "") ->
        {:error, Errors.new("INVALID_MESSAGE", "initial_members user_id required")}

      member_id == user_id ->
        {:error, Errors.new("INVALID_MESSAGE", "creator must not be in initial_members")}

      true ->
        {:ok, %{"user_id" => member_id, "role" => role}}
    end
  end

  defp parse_initial_member(_im, _user_id),
    do: {:error, Errors.new("INVALID_MESSAGE", "initial_members role must be member or admin")}

  # Old Worker: JSON.stringify over the normalized body, fixed key order.
  # Phase 3 accepts only a null avatar (non-null is rejected earlier), so the
  # hashed avatar is always null.
  defp create_request_hash(parsed) do
    [
      {"title", parsed[:raw_title]},
      {"topic", parsed[:topic]},
      {"avatar_attachment_id", nil},
      {"visibility", parsed[:visibility]},
      {"initial_members", Enum.map(parsed[:initial_members], &initial_member_json/1)}
    ]
    |> CanonicalJSON.encode_and_sha256()
  end

  defp initial_member_json(im), do: [{"user_id", im["user_id"]}, {"role", im["role"]}]

  defp do_create(channel_id, user_id, seq, command_id, parsed, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    initial_members = parsed[:initial_members]
    member_count = 1 + length(initial_members)

    # Event plan, in commit order (one monotonic event_id each, allocated
    # from the writer seq before the txn): channel.created, the creator's
    # member.joined, one member.joined per initial member, system.notice.
    # The stored payloads keep the reference fields (old Worker persisted
    # shape); replay re-projects them via the shared Projections builders.
    im_steps =
      initial_members
      |> Enum.with_index(1)
      |> Enum.map(fn {im, i} ->
        {"member.joined", member_joined_payload(channel_id, im["user_id"], im["role"], i + 1),
         i + 1}
      end)

    steps =
      [
        {
          "channel.created",
          %{
            "channel" => %{
              "channel_id" => channel_id,
              "kind" => "channel",
              "visibility" => parsed[:visibility],
              "title" => parsed[:title]
            },
            "actor_kind" => "user",
            "actor_id" => user_id
          },
          1
        },
        {"member.joined", member_joined_payload(channel_id, user_id, "owner", 1), 1}
      ] ++
        im_steps ++
        [
          {
            "system.notice",
            %{
              "notice_kind" => "channel.created",
              "actor_user_id" => user_id,
              "target_user_id" => nil,
              "message_id" => nil,
              "channel_changes" => nil
            },
            member_count
          }
        ]

    {events, new_seq} =
      Enum.map_reduce(steps, seq, fn {type, payload, mv}, s ->
        {event_id, s2} = Ids.monotonic_uuidv7(s, now_ms)
        {{type, event_id, payload, mv}, s2}
      end)

    profiles =
      [user_id]
      |> Kernel.++(Enum.map(initial_members, & &1["user_id"]))
      |> Enum.uniq()
      |> Profiles.resolve()

    frames =
      Enum.map(events, fn {type, event_id, payload, mv} ->
        wire =
          case type do
            "system.notice" -> notice_wire(payload, profiles)
            _ -> Projections.resolve_actor(payload, profiles)
          end

        Projections.build_event_frame(event_id, type, channel_id, now, wire)
        |> Map.put("membership_version_at_event", mv)
      end)

    response = create_response(channel_id, parsed, now)

    hints =
      [{user_id, "channel_joined"}] ++
        Enum.map(initial_members, &{&1["user_id"], "channel_joined"})

    result =
      run_idempotent_txn(user_id, "channel.create", command_id, request_hash, fn ->
        insert_channel(channel_id, parsed, user_id, now, member_count)
        insert_member(channel_id, user_id, "owner", now)

        Enum.each(initial_members, fn im ->
          insert_member(channel_id, im["user_id"], im["role"], now)
        end)

        Enum.each(events, fn {type, event_id, payload, mv} ->
          insert_event(event_id, type, channel_id, payload, mv, now)
        end)

        Idempotency.write_completed(
          "user",
          user_id,
          "channel.create",
          command_id,
          request_hash,
          response
        )

        %{
          kind: :created,
          response: response,
          event_frames: frames,
          user_hints: hints,
          seq: new_seq
        }
      end)

    finalize(result, seq)
  end

  defp member_joined_payload(channel_id, user_id, role, mv) do
    %{
      "channel_id" => channel_id,
      "user_id" => user_id,
      "role" => role,
      "membership_version" => mv,
      "actor_kind" => "system",
      "actor_id" => "system",
      "join_source" => nil,
      "inviter_user_id" => nil
    }
  end

  defp create_response(channel_id, parsed, now) do
    ts = Projections.format_ts(now)

    %{
      "channel" => %{
        "channel_id" => channel_id,
        "kind" => "channel",
        "visibility" => parsed[:visibility],
        "title" => parsed[:title],
        "topic" => parsed[:topic],
        "avatar_url" => nil,
        "member_count" => 1 + length(parsed[:initial_members]),
        "status" => "active",
        "created_at" => ts,
        "updated_at" => ts
      },
      "membership" => %{"role" => "owner", "joined_at" => ts}
    }
  end

  defp insert_channel(channel_id, parsed, user_id, now, member_count) do
    Repo.query!(
      """
      INSERT INTO chat_v2.channels (
        channel_id, kind, visibility, title, topic, avatar_url, status,
        created_by, created_at, updated_at, member_count, membership_version
      ) VALUES ($1, 'channel', $2, $3, $4, NULL, 'active', $5, $6, $6, $7, $8)
      """,
      [
        channel_id,
        parsed[:visibility],
        parsed[:title],
        parsed[:topic],
        user_id,
        now,
        member_count,
        member_count
      ],
      type: true
    )
  end

  # --------------------------------------------------------------------------
  # update
  # --------------------------------------------------------------------------

  # Presence-aware parse: only keys PRESENT in the body are normalized
  # (`:absent` = not in body). Value-level type checks happen here (the old
  # Worker stores whatever JSON arrives, but the v2 text columns need a
  # binary or null); the visibility ENUM check stays in-txn after the role
  # gate, matching the old Worker's error order.
  defp parse_update(payload) when is_map(payload) do
    with {:ok, title} <-
           read_update_field(
             payload,
             "title",
             &(&1 === nil or is_binary(&1)),
             "title must be a string or null"
           ),
         {:ok, topic} <-
           read_update_field(
             payload,
             "topic",
             &(&1 === nil or is_binary(&1)),
             "topic must be a string or null"
           ),
         {:ok, avatar} <-
           read_update_field(
             payload,
             "avatar_attachment_id",
             &(&1 === nil or is_binary(&1)),
             "avatar_attachment_id must be a string or null"
           ),
         {:ok, visibility} <-
           read_update_field(payload, "visibility", &is_binary/1, "visibility must be a string") do
      avatar =
        case avatar do
          :absent ->
            :absent

          nil ->
            nil

          _ ->
            {:error,
             Errors.new("INVALID_MESSAGE", "avatar_attachment_id not supported in Phase 3")}
        end

      case avatar do
        {:error, _} = err -> err
        _ -> {:ok, %{title: title, topic: topic, avatar: avatar, visibility: visibility}}
      end
    end
  end

  defp parse_update(_payload),
    do: {:error, Errors.new("INVALID_MESSAGE", "payload must be an object")}

  defp read_update_field(payload, key, validator, message) do
    if Map.has_key?(payload, key) do
      value = payload[key]

      if validator.(value) do
        {:ok, value}
      else
        {:error, Errors.new("INVALID_MESSAGE", message)}
      end
    else
      {:ok, :absent}
    end
  end

  # Old Worker: only the fields PRESENT in the body, in contract order. An
  # empty body hashes the empty object (`"{}"`), matching the old Worker's
  # `JSON.stringify({})` (an empty canonical list would encode `"[]"`).
  defp update_request_hash(parsed) do
    fields =
      [
        present_field(parsed, :title, "title"),
        present_field(parsed, :topic, "topic"),
        present_field(parsed, :avatar, "avatar_attachment_id"),
        present_field(parsed, :visibility, "visibility")
      ]
      |> Enum.reject(&is_nil/1)

    canonical = if fields == [], do: %{}, else: fields
    CanonicalJSON.encode_and_sha256(canonical)
  end

  defp present_field(parsed, key, json_key) do
    case parsed[key] do
      :absent -> nil
      value -> {json_key, value}
    end
  end

  defp do_update(channel_id, user_id, seq, command_id, parsed, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    # Bounded preflight read: resolves the actor profile for the live
    # projection (old Worker P0-2 preflight parity).
    profiles = Profiles.resolve([user_id])

    result =
      run_idempotent_txn(user_id, "channel.update", command_id, request_hash, fn ->
        do_update_inner(
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

  defp do_update_inner(
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
          role = active_role(channel_id, user_id)

          if role not in ["owner", "admin"] do
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("FORBIDDEN", "not authorized to update channel")
            })
          else
            apply_update(
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
  end

  defp apply_update(
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
    mv = meta["membership_version"]
    {changes, new} = compute_changes(parsed, meta)

    # Old Worker order: the enum check runs in-txn, after the role gate.
    if field_present?(parsed, :visibility) and new["visibility"] not in @visibilities do
      Repo.rollback(%{kind: :error, error: Errors.new("INVALID_MESSAGE", "invalid visibility")})
    else
      {frames, seq_after} =
        if changes == %{} do
          {[], seq}
        else
          update_channel_row(channel_id, new, now)
          {updated_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
          {notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)

          updated_payload = %{
            "channel_id" => channel_id,
            "channel_changes" => changes,
            "actor_kind" => "user",
            "actor_id" => user_id
          }

          insert_event(updated_id, "channel.updated", channel_id, updated_payload, mv, now)

          notice_payload = %{
            "notice_kind" => "channel.updated",
            "actor_user_id" => user_id,
            "target_user_id" => nil,
            "message_id" => nil,
            "channel_changes" => changes
          }

          insert_notice_event(notice_id, channel_id, user_id, notice_payload, mv, now)

          {
            [
              event_frame(
                updated_id,
                "channel.updated",
                channel_id,
                now,
                updated_payload,
                mv,
                profiles
              ),
              notice_frame(notice_id, channel_id, now, notice_payload, mv, profiles)
            ],
            s2
          }
        end

      response = %{"channel" => channel_projection(meta, new, changes, now)}

      Idempotency.write_completed(
        "user",
        user_id,
        "channel.update",
        command_id,
        request_hash,
        response
      )

      %{
        kind: :updated,
        response: response,
        event_frames: frames,
        user_hints: [],
        seq: seq_after
      }
    end
  end

  defp compute_changes(parsed, meta) do
    new = %{
      "title" => resolve_field(parsed, :title, meta["title"]),
      "topic" => resolve_field(parsed, :topic, meta["topic"]),
      "avatar_url" => resolve_field(parsed, :avatar, meta["avatar_url"]),
      "visibility" => resolve_field(parsed, :visibility, meta["visibility"])
    }

    changes =
      %{}
      |> put_change("title", meta["title"], new["title"], field_present?(parsed, :title))
      |> put_change("topic", meta["topic"], new["topic"], field_present?(parsed, :topic))
      |> put_change(
        "avatar_url",
        meta["avatar_url"],
        new["avatar_url"],
        field_present?(parsed, :avatar)
      )
      |> put_change(
        "visibility",
        meta["visibility"],
        new["visibility"],
        field_present?(parsed, :visibility)
      )

    {changes, new}
  end

  defp resolve_field(parsed, key, current) do
    case parsed[key] do
      :absent -> current
      value -> value
    end
  end

  defp field_present?(parsed, key) do
    case Map.fetch!(parsed, key) do
      :absent -> false
      _ -> true
    end
  end

  defp put_change(changes, key, before, new_value, present?) do
    if present? and before != new_value do
      Map.put(changes, key, %{"before" => before, "after" => new_value})
    else
      changes
    end
  end

  defp update_channel_row(channel_id, new, now) do
    Repo.query!(
      """
      UPDATE chat_v2.channels
      SET title = $2, topic = $3, avatar_url = $4, visibility = $5, updated_at = $6
      WHERE channel_id = $1
      """,
      [channel_id, new["title"], new["topic"], new["avatar_url"], new["visibility"], now],
      type: true
    )
  end

  # The response `channel` projection: ChannelMetaProjection (10 fields,
  # old `src/contract/channel-api.ts`), with the updated-at bump only when
  # something actually changed (old Worker parity).
  defp channel_projection(meta, new, changes, now) do
    updated_at = if changes == %{}, do: meta["updated_at"], else: now

    %{
      "channel_id" => meta["channel_id"],
      "kind" => meta["kind"],
      "visibility" => new["visibility"],
      "title" => new["title"],
      "topic" => new["topic"],
      "avatar_url" => new["avatar_url"],
      "member_count" => meta["member_count"],
      "status" => meta["status"],
      "created_at" => Projections.format_ts(meta["created_at"]),
      "updated_at" => Projections.format_ts(updated_at)
    }
  end

  # --------------------------------------------------------------------------
  # dissolve
  # --------------------------------------------------------------------------

  defp do_dissolve(channel_id, user_id, seq, command_id, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    profiles = Profiles.resolve([user_id])

    result =
      run_idempotent_txn(user_id, "channel.dissolve", command_id, request_hash, fn ->
        do_dissolve_inner(
          channel_id,
          user_id,
          seq,
          command_id,
          request_hash,
          profiles,
          now,
          now_ms
        )
      end)

    finalize(result, seq)
  end

  defp do_dissolve_inner(
         channel_id,
         user_id,
         seq,
         command_id,
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
        if meta["status"] == "dissolved" do
          # Already dissolved: the old Worker records the response for THIS
          # key (a same-key retry replays it) and returns the tombstone
          # without re-emitting events or user hints.
          response = dissolve_response(channel_id, now)

          Idempotency.write_completed(
            "user",
            user_id,
            "channel.dissolve",
            command_id,
            request_hash,
            response
          )

          %{kind: :dissolved, response: response, event_frames: [], user_hints: [], seq: seq}
        else
          # Old Worker owner gate: channels.created_by (revisited in #12
          # once owner transfer exists).
          if meta["created_by"] != user_id do
            Repo.rollback(%{
              kind: :error,
              error: Errors.new("FORBIDDEN", "only owner may dissolve")
            })
          else
            mv = meta["membership_version"] + 1
            affected = active_member_ids(channel_id)
            dissolved_at = Projections.format_ts(now)

            Repo.query!(
              """
              UPDATE chat_v2.channels
              SET status = 'dissolved', membership_version = $2, updated_at = $3
              WHERE channel_id = $1
              """,
              [channel_id, mv, now],
              type: true
            )

            {dissolved_id, s1} = Ids.monotonic_uuidv7(seq, now_ms)
            {notice_id, s2} = Ids.monotonic_uuidv7(s1, now_ms)

            dissolved_payload = %{
              "channel_id" => channel_id,
              "status" => "dissolved",
              "dissolved_at" => dissolved_at,
              "actor_kind" => "user",
              "actor_id" => user_id
            }

            insert_event(
              dissolved_id,
              "channel.dissolved",
              channel_id,
              dissolved_payload,
              mv,
              now
            )

            notice_payload = %{
              "notice_kind" => "channel.dissolved",
              "actor_user_id" => user_id,
              "target_user_id" => nil,
              "message_id" => nil,
              "channel_changes" => nil
            }

            insert_notice_event(notice_id, channel_id, user_id, notice_payload, mv, now)

            frames = [
              event_frame(
                dissolved_id,
                "channel.dissolved",
                channel_id,
                now,
                dissolved_payload,
                mv,
                profiles
              ),
              notice_frame(notice_id, channel_id, now, notice_payload, mv, profiles)
            ]

            response = dissolve_response(channel_id, now)

            Idempotency.write_completed(
              "user",
              user_id,
              "channel.dissolve",
              command_id,
              request_hash,
              response
            )

            %{
              kind: :dissolved,
              response: response,
              event_frames: frames,
              user_hints: Enum.map(affected, &{&1, "channel_dissolved"}),
              seq: s2
            }
          end
        end
    end
  end

  defp dissolve_response(channel_id, now) do
    %{
      "channel" => %{
        "channel_id" => channel_id,
        "status" => "dissolved",
        "updated_at" => Projections.format_ts(now)
      }
    }
  end

  # --------------------------------------------------------------------------
  # idempotency (D10/D11)
  # --------------------------------------------------------------------------

  # The authoritative in-txn idempotency re-check, shared by all three
  # commands. The pre-txn `Idempotency.check` at each entry point is a cheap
  # fast path; this re-check runs inside the transaction so a concurrent
  # duplicate cannot slip past. `missing_fn` performs the business writes +
  # `Idempotency.write_completed` and returns the committed result
  # (kind: :created / :updated / :dissolved, plus `seq` — the writer's next
  # seq).
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
      when kind in [:created, :updated, :dissolved] ->
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

  # Old Worker `assertChannelKindChannel` (pre-txn parity).
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
        SELECT channel_id, kind, visibility, title, topic, avatar_url, status, created_by,
               created_at, updated_at, member_count, membership_version
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
        "SELECT role FROM chat_v2.channel_members WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
        [channel_id, user_id]
      )
    )
    |> List.first()
    |> case do
      %{"role" => role} -> role
      _ -> nil
    end
  end

  defp active_member_ids(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT user_id FROM chat_v2.channel_members WHERE channel_id = $1 AND status = 'active' ORDER BY user_id",
        [channel_id]
      )
    )
    |> Enum.map(& &1["user_id"])
  end

  defp insert_member(channel_id, user_id, role, now) do
    Repo.query!(
      "INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, left_at, status)
       VALUES ($1, $2, $3, $4, NULL, 'active')",
      [channel_id, user_id, role, now],
      type: true
    )
  end

  # --------------------------------------------------------------------------
  # events + frames (stored payloads keep reference fields; the wire payload
  # is re-projected with the shared Projections builders, identical to replay)
  # --------------------------------------------------------------------------

  defp insert_event(event_id, event_type, channel_id, payload, mv, now) do
    {actor_kind, actor_id} =
      case event_type do
        "system.notice" -> {"user", payload["actor_user_id"]}
        _ -> {payload["actor_kind"], payload["actor_id"]}
      end

    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id, payload,
        membership_version_at_event, occurred_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [event_id, event_type, channel_id, actor_kind, actor_id, payload, mv, now],
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
