defmodule LiliumChat.Observability.SocketTracker do
  @moduledoc """
  Live WebSocket connection counter (spec §10 WS 连接数, issue #21).

  Phoenix does not emit a socket-disconnect telemetry event, and
  `Phoenix.Socket`'s injected default `terminate/2` cannot be overridden,
  so each socket's `connect/3` calls `track/1` after a successful
  handshake and this GenServer monitors the socket process: when it dies
  (disconnect / crash), the count for its transport is decremented.

  `counts/0` backs the `lilium_chat.websocket.connections` gauge emitted
  by `LiliumChat.Observability.runtime_gauges/0`.
  """

  use GenServer

  @transports [:browser, :bot, :bot_stream]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Register the calling socket process under `transport`. Safe to call more
  than once for the same process (the second call is a no-op).
  """
  def track(transport) when transport in @transports do
    GenServer.cast(__MODULE__, {:track, self(), transport})
    :ok
  end

  @doc "Live connection counts per transport: `%{transport => count}`."
  def counts do
    GenServer.call(__MODULE__, :counts)
  end

  @doc """
  The WS transports this tracker knows (`:browser` / `:bot` / `:bot_stream`) —
  the single source of the list, so the gauge emission in
  `LiliumChat.Observability.runtime_gauges/0` cannot drift from it.
  """
  def transports, do: @transports

  @impl true
  def init(_), do: {:ok, %{counts: %{}, refs: %{}}}

  @impl true
  def handle_cast({:track, pid, transport}, state) do
    if Map.has_key?(state.refs, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)

      counts = Map.update(state.counts, transport, 1, &(&1 + 1))
      refs = Map.put(state.refs, pid, {ref, transport})

      {:noreply, %{state | counts: counts, refs: refs}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.refs, pid) do
      {{^ref, transport}, refs} ->
        counts = Map.update(state.counts, transport, 1, &max(&1 - 1, 0))
        {:noreply, %{state | counts: counts, refs: refs}}

      # A duplicate DOWN (or a pid tracked then re-monitored) — ignore.
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}
    end
  end

  @impl true
  def handle_call(:counts, _from, state) do
    {:reply, state.counts, state}
  end
end
