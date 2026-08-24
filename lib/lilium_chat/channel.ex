defmodule LiliumChat.Channel do
  @moduledoc """
  Per-channel writer process — the `Channel.<channel_id>` GenServer
  (spec §2.2 / §5.1, D13, issue #9).

  One lazily-started GenServer per channel, supervised by the
  `LiliumChat.ChannelConnections` dynamic supervisor. It is the **single
  writer** for the channel's events: because a GenServer processes calls
  sequentially, every `message.send` (and, later, the #10 mutations) commits
  in order, and the in-process monotonic `event_id` counter is never raced.

  The process owns the per-channel `event_id` sequence state (`seq`) in
  memory (spec §5.1 / D13 — *runtime state, no PG seq table*). On (re)start it
  recovers the counter from `MAX(chat_v2.events.event_id)` via
  `Ids.parse_monotonic/1`, so a crash leaves the per-channel sequence monotonic.
  """

  use GenServer

  alias LiliumChat.{
    BotConnection,
    BotEffects,
    ChannelJoin,
    ChannelLifecycle,
    ChannelPins,
    Dms,
    Errors,
    Ids,
    InviteCommands,
    MemberCommands,
    MessageMutate,
    MessageSend,
    Query,
    Repo,
    StatefulSessions,
    StreamWrite
  }

  alias LiliumChat.WebSockets.Frames

  require Logger

  # ------------------------------------------------------------- lifecycle

  @doc "Child spec for the dynamic supervisor (child id = channel_id)."
  def child_spec(channel_id) do
    %{
      id: {__MODULE__, channel_id},
      start: {__MODULE__, :start_link, [channel_id]},
      type: :worker,
      restart: :temporary
    }
  end

  def start_link(channel_id) when is_binary(channel_id) do
    GenServer.start_link(__MODULE__, channel_id, name: via_registry(channel_id))
  end

  @doc """
  Ensure the channel's writer process exists (lazy start). Returns `{:ok, pid}`
  (the process may already exist).
  """
  def ensure_started(channel_id) do
    case DynamicSupervisor.start_child(LiliumChat.ChannelConnections, child_spec(channel_id)) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  # --------------------------------------------------------------- message.send

  @doc """
  Route a validated `message.send` command through the channel's writer
  process. `input` is `%{user_id: binary, command_id: binary, payload: map}`.

  Returns `{:ok, ack_frame}` (committed — a fresh commit or an idempotent
  replay of a prior commit) or `{:error, %LiliumChat.Errors.ApiError{}}`.
  On a fresh commit the process also broadcasts the `message.created` event
  frame on `channel:<channel_id>` for the live fanout (issue #8 gate).
  """
  def send_message(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:send_message, input}, 30_000)
  end

  # ------------------------------------------------------- message mutations

  @doc """
  Route `message.edit` / `message.recall` / `message.delete` through the
  channel's writer process (issue #10). `input` is
  `%{user_id: binary, command_id: binary, operation: binary, payload: map}`.

  Returns `{:ok, ack_frame}` or `{:error, %LiliumChat.Errors.ApiError{}}`.
  On a fresh commit the process also broadcasts the lifecycle event frames
  (`message.updated` / `message.recalled` / `message.deleted`, plus the
  pin-lifecycle and `system.notice` frames) on `channel:<channel_id>` in
  event_id order.
  """
  def mutate_message(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:mutate_message, input}, 30_000)
  end

  @doc """
  Route `channel.pin_message` / `channel.unpin_message` through the channel's
  writer process (issue #10). `input` is
  `%{user_id: binary, command_id: binary, payload: map}`.

  Returns `{:ok, ack_frame}` or `{:error, %LiliumChat.Errors.ApiError{}}`.
  On a fresh commit the process also broadcasts the `channel.pin.*` event
  frame on `channel:<channel_id>`.
  """
  def pin_message(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:pin_message, input}, 30_000)
  end

  def unpin_message(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:unpin_message, input}, 30_000)
  end

  # ----------------------------------------------------- channel lifecycle

  @doc """
  Create a channel (`POST /api/chat/channels`, contract §5.2b, issue #11).
  `key` is the `Idempotency-Key`; `body` the JSON request body. The channel
  id is minted here (UUIDv7) and the create runs on the NEW channel's
  writer, whose `seq` seeds at 0 (no events exist yet).

  Returns `{:ok, response}` (the 201 response body — a fresh commit or an
  idempotent replay) or `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def create(user_id, key, body) do
    channel_id = Ids.uuidv7()
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:create_channel, %{user_id: user_id, command_id: key, payload: body || %{}}},
      30_000
    )
  end

  @doc """
  Update a channel (`PATCH /api/chat/channels/{channel_id}`, contract §5.3,
  issue #11). Returns `{:ok, response}` or `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def update(user_id, key, channel_id, body) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:update_channel, %{user_id: user_id, command_id: key, payload: body || %{}}},
      30_000
    )
  end

  @doc """
  Dissolve a channel (`POST /api/chat/channels/{channel_id}/dissolve`,
  contract §5.4, issue #11). Returns `{:ok, response}` or
  `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def dissolve(user_id, key, channel_id) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:dissolve_channel, %{user_id: user_id, command_id: key}}, 30_000)
  end

  # ---------------------------------------------------- member management

  @doc """
  Add a member (`POST /api/chat/channels/{channel_id}/members`, contract
  §7.2, issue #12). `body` is the JSON request body (target user in the
  body's `user_id`). Returns `{:ok, response}` or
  `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def add_member(user_id, key, channel_id, body) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:add_member, %{user_id: user_id, command_id: key, payload: body || %{}}},
      30_000
    )
  end

  @doc """
  Change a member's role (`PATCH /api/chat/channels/{channel_id}/members/{user_id}`,
  contract §7.3, issue #12). `body` is the JSON request body. Returns
  `{:ok, response}` or `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def update_member_role(user_id, key, channel_id, target_user_id, body) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:update_member_role,
       %{user_id: user_id, command_id: key, target_user_id: target_user_id, payload: body || %{}}},
      30_000
    )
  end

  @doc """
  Remove a member or self-leave (`DELETE /api/chat/channels/{channel_id}/members/{user_id}`,
  contract §7.4, issue #12). Returns `{:ok, response}` or
  `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def remove_member(user_id, key, channel_id, target_user_id) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:remove_member, %{user_id: user_id, command_id: key, target_user_id: target_user_id}},
      30_000
    )
  end

  @doc """
  Atomically transfer ownership (`POST /api/chat/channels/{channel_id}/owner-transfer`,
  contract §7.5, issue #12). `body` is the JSON request body. Returns
  `{:ok, response}` or `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def transfer_owner(user_id, key, channel_id, body) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:transfer_owner, %{user_id: user_id, command_id: key, payload: body || %{}}},
      30_000
    )
  end

  # ---------------------------------------------------------------- join (#13)

  @doc """
  Join a public channel (`POST /api/chat/channels/{channel_id}/join`,
  contract §5.7, issue #13). Returns `{:ok, response}` or
  `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def join_channel(user_id, key, channel_id) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:join_channel, %{user_id: user_id, command_id: key}}, 30_000)
  end

  # ---------------------------------------------------------- invites (#13)

  @doc """
  Create (or refresh) the caller's personal invite
  (`POST /api/chat/channels/{channel_id}/invites`, contract §5.8,
  issue #13). `body` is the JSON request body. Returns `{:ok, response}`
  or `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def create_invite(user_id, key, channel_id, body) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:create_invite, %{user_id: user_id, command_id: key, payload: body || %{}}},
      30_000
    )
  end

  @doc """
  Accept an invite (`POST /api/chat/invites/{invite_code}/accept`,
  contract §5.9, issue #13). `channel_id` is the routing channel resolved
  by `LiliumChat.InviteCommands.route_for/1` (the URL has no channel id).
  Returns `{:ok, response}` or `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def accept_invite(user_id, key, channel_id, invite_code) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(
      pid,
      {:accept_invite, %{user_id: user_id, command_id: key, invite_code: invite_code}},
      30_000
    )
  end

  # ------------------------------------------------------------- DM open (#13)

  @doc """
  Route a `dm.open` through the target channel's writer (contract §5.2c,
  issue #13). `input` is `%{user_id: binary, command_id: binary,
  recipient_user_id: binary}` — the caller (`LiliumChat.Dms`) resolves the
  routing channel via `dm_pairs` first. Returns `{:ok, response}` or
  `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def open_dm(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:open_dm, input}, 30_000)
  end

  # ---------------------------------------------------------- stream (#18)

  @doc """
  Persist a stream finalize through the channel writer (contract §9.15.4).
  `input` is the `StreamWrite.finalize/3` map. Returns `{:ok, response}`
  (`%{message_id, event_id}`) or `{:error, %Errors.ApiError{}}`.
  """
  def finalize_stream(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:finalize_stream, input}, 30_000)
  end

  @doc """
  Persist a non-empty stream abandon through the channel writer
  (contract §9.15.5). Returns `{:ok, response}` or
  `{:error, %Errors.ApiError{}}`.
  """
  def abandon_stream(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:abandon_stream, input}, 30_000)
  end

  # ------------------------------------------------- bot effects (#17 → #19)

  @doc """
  Apply a `delivery_result` effect batch through the channel writer
  (contract §9.14, issue #19 — old Worker `applyBotEffects` parity).
  `input` is `%{bot_id: binary, effects: list, is_official: bool,
  allow_session_control: bool, session_id: binary | nil}`.

  Returns `{:ok, %{effect_results, event_frames}}` or
  `{:error, %Errors.ApiError{}}`.
  """
  def apply_bot_effects(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:apply_bot_effects, input}, 30_000)
  end

  # --------------------------------------------------- stateful sessions (#19)

  @doc """
  Handle a bot `session.effects` frame (contract §9.7.3). `input`:
  `%{bot_id, session_id, effect_seq, effects}`. Returns `{:ok, ack_frame}`
  (a `session.effects_ack` frame) or `{:error, %Errors.ApiError{}}`.
  """
  def session_effects(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:session_effects, input}, 30_000)
  end

  @doc """
  Handle a bot `session.close` frame (contract §9.7.4). `input`:
  `%{bot_id, session_id, reason}`. Returns `{:ok, %{}}` or
  `{:error, %Errors.ApiError{}}`.
  """
  def session_close(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:session_close, input}, 30_000)
  end

  @doc """
  Handle a bot `session.input_ack` frame (contract §9.7.4). `input`:
  `%{session_id, last_received_seq}`. Returns `{:ok, %{}}` or
  `{:error, %Errors.ApiError{}}`.
  """
  def session_input_ack(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:session_input_ack, input}, 30_000)
  end

  @doc """
  The `platform:stop_session` platform shortcut (contract §9.12.2,
  issue #19 acceptance A5). `input`: `%{pin_id, user_id, admin}` —
  the caller has already resolved owner/admin. Returns
  `{:ok, committed_ack_payload}` (the `command_ack` payload the interaction
  handler wraps) or `{:error, %Errors.ApiError{}}`.
  """
  def request_stop(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:request_stop, input}, 30_000)
  end

  @doc """
  Browser `interaction.submit` (contract §9.5, brief §5/§10). `input`:
  `%{user_id, command_id, payload}` — payload carries `message_id` XOR
  `pin_id` + `component_id` + `custom_id` + `value`. Returns
  `{:ok, ack_payload}` (the `interaction.submit` response) or
  `{:error, %Errors.ApiError{}}`.
  """
  def submit_interaction(channel_id, input) do
    {:ok, pid} = ensure_started(channel_id)

    GenServer.call(pid, {:submit_interaction, input}, 30_000)
  end

  # --------------------------------------------------------- server callbacks

  @impl true
  def init(channel_id) do
    # Recover the monotonic counter from the newest committed event (crash
    # recovery, spec §5.1). An empty channel seeds the counter at 0.
    seq = recover_seq(channel_id)
    state = %{channel_id: channel_id, seq: seq}

    rearm_session_timers(state)

    Logger.debug("channel writer started: #{channel_id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, input}, _from, state),
    do: run_command(state, fn -> MessageSend.send(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:mutate_message, input}, _from, state),
    do: run_command(state, fn -> MessageMutate.mutate(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:pin_message, input}, _from, state),
    do: run_command(state, fn -> ChannelPins.pin_message(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:unpin_message, input}, _from, state),
    do:
      run_command(state, fn -> ChannelPins.unpin_message(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:create_channel, input}, _from, state),
    do: run_command(state, fn -> ChannelLifecycle.create(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:update_channel, input}, _from, state),
    do: run_command(state, fn -> ChannelLifecycle.update(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:dissolve_channel, input}, _from, state),
    do:
      run_command(state, fn -> ChannelLifecycle.dissolve(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:add_member, input}, _from, state),
    do: run_command(state, fn -> MemberCommands.add(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:update_member_role, input}, _from, state),
    do:
      run_command(state, fn -> MemberCommands.update_role(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:remove_member, input}, _from, state),
    do: run_command(state, fn -> MemberCommands.remove(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:transfer_owner, input}, _from, state),
    do:
      run_command(state, fn ->
        MemberCommands.transfer_owner(state.channel_id, state.seq, input)
      end)

  @impl true
  def handle_call({:join_channel, input}, _from, state),
    do: run_command(state, fn -> ChannelJoin.join(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:create_invite, input}, _from, state),
    do: run_command(state, fn -> InviteCommands.create(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:accept_invite, input}, _from, state),
    do: run_command(state, fn -> InviteCommands.accept(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:open_dm, input}, _from, state),
    do: run_command(state, fn -> Dms.open_dm(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:finalize_stream, input}, _from, state),
    do: run_command(state, fn -> StreamWrite.finalize(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:abandon_stream, input}, _from, state),
    do: run_command(state, fn -> StreamWrite.abandon(state.channel_id, state.seq, input) end)

  @impl true
  def handle_call({:apply_bot_effects, input}, _from, state) do
    run_command(state, fn ->
      case BotEffects.apply_effects(
             state.channel_id,
             state.seq,
             input[:bot_id],
             input[:effects] || [],
             is_official: input[:is_official] || false,
             allow_session_control: input[:allow_session_control] || false,
             session_id: input[:session_id]
           ) do
        {result, new_seq} -> {Map.put(result, :kind, :applied), new_seq}
      end
    end)
  end

  @impl true
  def handle_call({:session_effects, input}, _from, state),
    do:
      run_command(state, fn ->
        StatefulSessions.handle_session_effects(state.channel_id, state.seq, %{
          bot_id: input[:bot_id],
          session_id: input[:session_id],
          effect_seq: input[:effect_seq],
          effects: input[:effects] || []
        })
      end)

  @impl true
  def handle_call({:session_close, input}, _from, state),
    do:
      run_command(state, fn ->
        StatefulSessions.handle_session_close(state.channel_id, state.seq, %{
          bot_id: input[:bot_id],
          session_id: input[:session_id],
          reason: input[:reason]
        })
      end)

  @impl true
  def handle_call({:session_input_ack, input}, _from, state) do
    run_command(state, fn ->
      case StatefulSessions.handle_input_ack(state.channel_id, %{
             session_id: input[:session_id],
             last_received_seq: input[:last_received_seq]
           }) do
        {:ok, session} -> {%{kind: :input_acked, session_id: session["session_id"]}, state.seq}
      end
    end)
  end

  @impl true
  def handle_call({:request_stop, input}, _from, state),
    do:
      run_command(state, fn ->
        StatefulSessions.request_stop(state.channel_id, state.seq, %{
          pin_id: input[:pin_id],
          user_id: input[:user_id],
          admin: input[:admin] || false
        })
      end)

  @impl true
  def handle_call({:submit_interaction, input}, _from, state),
    do:
      run_command(state, fn ->
        StatefulSessions.submit_interaction(state.channel_id, state.seq, %{
          user_id: input[:user_id],
          command_id: input[:command_id],
          payload: input[:payload] || %{}
        })
      end)

  # Shared dispatch for every write command: run the domain op, rescue the
  # pre-txn business errors (all raises happen before the event_id is
  # allocated, so the held seq is unchanged), broadcast the committed event
  # frames (in event_id order) + the user-scoped `my_channels_changed` hints,
  # and reply with the ack / response.
  defp run_command(state, fun) do
    {result, _new_seq, state_after} = execute(state, fun)

    {:reply, to_reply(result), state_after}
  end

  # The `handle_info` variant (stop-grace / expiry timers): no caller to
  # reply to.
  defp run_command_info(state, fun) do
    {_result, _new_seq, state_after} = execute(state, fun)

    {:noreply, state_after}
  end

  defp execute(state, fun) do
    {result, new_seq} =
      try do
        fun.()
      rescue
        api_error in [Errors.ApiError] ->
          {%{kind: :error, error: api_error}, state.seq}
      end

    broadcast_frames(state.channel_id, result)
    broadcast_user_hints(state.channel_id, result)
    push_session_frames(result)
    arm_timers(result)

    {result, new_seq, Map.put(state, :seq, new_seq)}
  end

  # --------------------------------------------------------------- internals

  # WS paths reply with the `command_ack` frame; the HTTP lifecycle paths
  # (issue #11) reply with the HTTP response body.
  defp to_reply(%{kind: :created, ack_frame: ack}), do: {:ok, ack}
  defp to_reply(%{kind: :cached, ack_frame: ack}), do: {:ok, ack}
  defp to_reply(%{kind: :created, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :updated, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :dissolved, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :added, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :role_updated, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :removed, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :transferred, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :joined, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :invite_created, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :opened, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :cached, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :finalized, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :abandoned, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :applied, effect_results: results}), do: {:ok, %{effect_results: results}}
  defp to_reply(%{kind: :session_effects, reply: reply}), do: {:ok, reply}
  defp to_reply(%{kind: :session_closed}), do: {:ok, %{}}
  defp to_reply(%{kind: :input_acked}), do: {:ok, %{}}
  defp to_reply(%{kind: :stopped, reply: reply}), do: {:ok, reply}
  defp to_reply(%{kind: :interaction_submitted, response: response}), do: {:ok, response}
  defp to_reply(%{kind: :closed}), do: {:ok, %{}}
  defp to_reply(%{kind: :error, error: api_error}), do: {:error, api_error}

  # `message.send` (issue #9) returns a single `event_frame`; the #10/#11
  # write paths return `event_frames` (a list, in event_id order). Both may
  # appear (a commit frame followed by post-commit close frames) — broadcast
  # in event_id order: the commit frame first.
  defp broadcast_frames(channel_id, result) do
    frames =
      if(result[:event_frame], do: [result[:event_frame]], else: []) ++
        List.wrap(result[:event_frames])

    Enum.each(frames, fn frame -> broadcast(channel_id, frame) end)
  end

  defp broadcast(channel_id, frame) do
    topic = "channel:" <> channel_id
    Phoenix.PubSub.broadcast(LiliumChat.PubSub, topic, {:broadcast, topic, frame})
  end

  # `my_channels_changed` (contract §10.5): after the lifecycle txn commits,
  # each affected user's `user:<uid>` topic gets the user-scoped hint; the
  # browser socket pushes it to the user's live sessions. Trigger set (D8):
  # join / leave / dissolve — NOT role change, NOT channel.update.
  defp broadcast_user_hints(channel_id, %{user_hints: hints})
       when is_list(hints) and hints != [] do
    Enum.each(hints, fn {user_id, reason} ->
      topic = "user:" <> user_id
      frame = Frames.user_event("my_channels_changed", reason, channel_id)
      Phoenix.PubSub.broadcast(LiliumChat.PubSub, topic, {:broadcast, topic, frame})
    end)
  end

  defp broadcast_user_hints(_channel_id, _result), do: :ok

  # Bot-scoped live frames (session.stop_requested / session.input /
  # session.closed): best-effort push through the Bot process — the durable
  # state lives in PG, the live push is fanout (old Worker parity).
  defp push_session_frames(%{push_frames: frames, push_bot_id: bot_id})
       when is_list(frames) and frames != [] and is_binary(bot_id) do
    Enum.each(frames, fn frame -> BotConnection.push_nowait(bot_id, frame) end)
  end

  defp push_session_frames(_result), do: :ok

  # Stop-grace timer (contract §9.12.2): force-close a `closing` session
  # that did not close within `grace_timeout_ms`.
  defp arm_timers(%{arm_grace: %{session_id: session_id, at: at}}) do
    Process.send_after(self(), {:session_stop_grace, session_id}, until_ms(at))
    :ok
  end

  defp arm_timers(_result), do: :ok

  # (Re)arm the session timers from durable state (writer (re)start,
  # old Worker alarm parity): `closing` sessions re-arm their stop grace;
  # `starting` / `active` / `suspended` sessions re-arm the TTL expiry.
  defp rearm_session_timers(state) do
    now_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)

    Enum.each(StatefulSessions.active_rows(state.channel_id), fn row ->
      session_id = row["session_id"]

      cond do
        row["status"] == "closing" and row["stop_grace_at"] != nil ->
          Process.send_after(
            self(),
            {:session_stop_grace, session_id},
            max(to_unix_ms(row["stop_grace_at"]) - now_ms, 0)
          )

        row["expires_at"] != nil ->
          Process.send_after(
            self(),
            {:session_expiry, session_id},
            max(to_unix_ms(row["expires_at"]) - now_ms, 0)
          )

        true ->
          :ok
      end
    end)

    :ok
  end

  # Raw `Repo.query` decodes `timestamptz` differently depending on the query
  # shape (parameterized results may arrive as NaiveDateTime). Accept both.
  defp to_unix_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp to_unix_ms(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp until_ms(at) do
    now_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)
    max(DateTime.to_unix(at, :millisecond) - now_ms, 0)
  end

  # Timer handlers run in the `handle_info` context (no GenServer caller).

  @impl true
  def handle_info({:session_stop_grace, session_id}, state) do
    case StatefulSessions.get(session_id) do
      %{"status" => "closing", "channel_id" => channel_id} ->
        if channel_id == state.channel_id do
          run_command_info(state, fn ->
            StatefulSessions.close(state.channel_id, state.seq, session_id, "stop_timeout")
          end)
        else
          {:noreply, state}
        end

      _ ->
        # Already closed / bot-closed first — the timer is stale.
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:session_expiry, session_id}, state) do
    case StatefulSessions.get(session_id) do
      %{"status" => status, "channel_id" => channel_id} ->
        if channel_id == state.channel_id and status in StatefulSessions.active_statuses() do
          run_command_info(state, fn ->
            # TTL elapsed → reason `timeout` (old Worker: status `failed`).
            StatefulSessions.close(state.channel_id, state.seq, session_id, "timeout")
          end)
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp recover_seq(channel_id) do
    case Query.rows(
           Repo.query(
             "SELECT event_id FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id DESC LIMIT 1",
             [channel_id]
           )
         ) do
      [%{"event_id" => event_id}] -> Ids.parse_monotonic(event_id)
      _ -> %{last_ms: 0, counter: 0}
    end
  end

  defp via_registry(key) do
    # 2-tuple form: the registry key IS the channel_id.
    {:via, Registry, {LiliumChat.Channels.Registry, key}}
  end
end
