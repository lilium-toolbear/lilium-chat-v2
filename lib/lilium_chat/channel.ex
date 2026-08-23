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

  alias LiliumChat.{Errors, Ids, MessageSend, Query, Repo}

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
  def handle_call({:send_message, input}, _from, state) do
    {result, new_seq} =
      try do
        MessageSend.send(state.channel_id, state.seq, input)
      rescue
        # Business errors raised during pre-txn resolution (reply target,
        # attachment / sticker availability) become a command_error, not a
        # process crash. All raises happen before the event_id is allocated,
        # so the held seq is unchanged.
        api_error in [Errors.ApiError] ->
          {%{kind: :error, error: api_error}, state.seq}
      end

    case result do
      %{kind: :created, event_frame: event_frame} ->
        broadcast(state.channel_id, event_frame)

      _ ->
        :ok
    end

    {:reply, to_reply(result), %{state | seq: new_seq}}
  end

  # --------------------------------------------------------------- internals

  defp to_reply(%{kind: :created, ack_frame: ack}), do: {:ok, ack}
  defp to_reply(%{kind: :cached, ack_frame: ack}), do: {:ok, ack}
  defp to_reply(%{kind: :error, error: api_error}), do: {:error, api_error}

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
