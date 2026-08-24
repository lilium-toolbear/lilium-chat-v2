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
    Repo
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

  # --------------------------------------------------------- server callbacks

  @impl true
  def init(channel_id) do
    # Recover the monotonic counter from the newest committed event (crash
    # recovery, spec §5.1). An empty channel seeds the counter at 0.
    seq = recover_seq(channel_id)

    Logger.debug("channel writer started: #{channel_id}")
    {:ok, %{channel_id: channel_id, seq: seq}}
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

  # Shared dispatch for every write command: run the domain op, rescue the
  # pre-txn business errors (all raises happen before the event_id is
  # allocated, so the held seq is unchanged), broadcast the committed event
  # frames (in event_id order) + the user-scoped `my_channels_changed` hints,
  # and reply with the ack / response.
  defp run_command(state, fun) do
    {result, new_seq} =
      try do
        fun.()
      rescue
        api_error in [Errors.ApiError] ->
          {%{kind: :error, error: api_error}, state.seq}
      end

    broadcast_frames(state.channel_id, result)
    broadcast_user_hints(state.channel_id, result)

    {:reply, to_reply(result), %{state | seq: new_seq}}
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
  defp to_reply(%{kind: :error, error: api_error}), do: {:error, api_error}

  # `message.send` (issue #9) returns a single `event_frame`; the #10/#11
  # write paths return `event_frames` (a list, in event_id order).
  defp broadcast_frames(channel_id, %{event_frame: frame}), do: broadcast(channel_id, frame)

  defp broadcast_frames(channel_id, %{event_frames: frames})
       when is_list(frames) and frames != [],
       do: Enum.each(frames, fn frame -> broadcast(channel_id, frame) end)

  defp broadcast_frames(_channel_id, _result), do: :ok

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
