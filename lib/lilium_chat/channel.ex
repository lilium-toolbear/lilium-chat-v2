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

  alias LiliumChat.{ChannelPins, Errors, Ids, MessageMutate, MessageSend, Query, Repo}

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

  # Shared dispatch for every write command: run the domain op, rescue the
  # pre-txn business errors (all raises happen before the event_id is
  # allocated, so the held seq is unchanged), broadcast the committed event
  # frames (in event_id order) and reply with the ack.
  defp run_command(state, fun) do
    {result, new_seq} =
      try do
        fun.()
      rescue
        api_error in [Errors.ApiError] ->
          {%{kind: :error, error: api_error}, state.seq}
      end

    broadcast_frames(state.channel_id, result)

    {:reply, to_reply(result), %{state | seq: new_seq}}
  end

  # --------------------------------------------------------------- internals

  defp to_reply(%{kind: :created, ack_frame: ack}), do: {:ok, ack}
  defp to_reply(%{kind: :cached, ack_frame: ack}), do: {:ok, ack}
  defp to_reply(%{kind: :error, error: api_error}), do: {:error, api_error}

  # `message.send` (issue #9) returns a single `event_frame`; the #10 write
  # paths return `event_frames` (a list, in event_id order).
  defp broadcast_frames(channel_id, %{kind: :created, event_frame: frame}),
    do: Enum.each([frame], fn frame -> broadcast(channel_id, frame) end)

  defp broadcast_frames(channel_id, %{kind: :created, event_frames: frames}),
    do: Enum.each(frames, fn frame -> broadcast(channel_id, frame) end)

  defp broadcast_frames(_channel_id, _result), do: :ok

  defp broadcast(channel_id, frame) do
    topic = "channel:" <> channel_id
    Phoenix.PubSub.broadcast(LiliumChat.PubSub, topic, {:broadcast, topic, frame})
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
