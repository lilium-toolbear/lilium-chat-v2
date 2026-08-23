defmodule LiliumChat.BotConnection do
  @moduledoc """
  Per-bot connection state — the `Bot.<bot_id>` process (spec §2.2 /
  issue #17).

  One lazily-started GenServer per bot, supervised by the
  `LiliumChat.BotConnections` dynamic supervisor. It owns:

    * the current channel pid + session id (set at `hello`, cleared on WS
      close / lease expiry);
    * the **connection lease** timer (contract §9.7.1: 60s default; every
      ping / delivery frame refreshes it; expiry → offline, the server closes
      the socket with reason `lease_expired`);
    * the **offline short-TTL** timer (contract §9.7: committed-but-undelivered
      rows are dropped / marked failed `offline_ttl_ms` after the bot goes
      away, unless the bot reconnects first — crash recovery, spec D14).

  Delivery hot path: commit APIs (`LiliumChat.BotDelivery`) push frames
  through this process (`push_frame/2`); `delivery_result` frames are
  routed here (`deliver_result/3`) so the lease refresh + PG work live in
  one place.
  """

  use GenServer

  require Logger

  alias LiliumChat.{BotDelivery, BotGateway, Ids}

  # ------------------------------------------------------------- lifecycle

  @doc "Child spec for the dynamic supervisor (child id = bot_id)."
  def child_spec(bot_id) do
    %{
      id: {__MODULE__, bot_id},
      start: {__MODULE__, :start_link, [bot_id]},
      type: :worker,
      restart: :temporary
    }
  end

  def start_link(bot_id) when is_binary(bot_id) do
    GenServer.start_link(__MODULE__, bot_id, name: via_registry(bot_id))
  end

  @doc """
  Ensure the bot's connection process exists (lazy start). Returns
  `{:ok, pid}` (the process may already exist).
  """
  def ensure_started(bot_id) do
    case DynamicSupervisor.start_child(LiliumChat.BotConnections, child_spec(bot_id)) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "Whether the bot currently has a connected WS channel (hello completed)."
  def online?(bot_id) do
    case pid_for(bot_id) do
      nil ->
        false

      pid ->
        try do
          GenServer.call(pid, :online?, 100)
        catch
          :exit, _ -> false
        end
    end
  end

  # ------------------------------------------------------------------ hello

  @doc """
  Handle a validated `hello` (from the bot channel). Registers the channel,
  generates a new session id, schedules the lease timer, and returns the
  `ready` payload plus the resume `delivery` frames (all `pending` rows,
  `delivery_id` order — the bot dedupes on `delivery_id`).

  `last_received_delivery_id` is validated by `BotGateway.parse_hello/1`
  and stored in state for observability, but — old-Worker parity — it is
  **not** a skip boundary: resume redelivers every pending row and the bot
  dedupes on `delivery_id`.
  """
  def connect(bot_id, channel_pid, last_received_delivery_id) do
    {:ok, _} = ensure_started(bot_id)

    GenServer.call(
      pid_for!(bot_id),
      {:connect, channel_pid, last_received_delivery_id},
      5_000
    )
  end

  # ------------------------------------------------------------------ lease

  @doc "Refresh the connection lease (ping / pong / any bot message)."
  def touch(bot_id) do
    if pid = pid_for(bot_id) do
      GenServer.cast(pid, :touch)
    end
  end

  # ----------------------------------------------------------------- result

  @doc """
  Route a `delivery_result` through the bot process (lease refresh +
  idempotent effect application). Returns the `delivery_ack` frame.
  """
  def deliver_result(bot_id, delivery_id, effects) do
    case pid_for(bot_id) do
      nil ->
        # No session at all: the bot can't have a valid delivery_id.
        BotGateway.build_delivery_ack(delivery_id, "failed", %{
          "error" => %{"code" => "BOT_EFFECT_INVALID", "message" => "unknown delivery_id"}
        })

      pid ->
        try do
          GenServer.call(pid, {:deliver_result, delivery_id, effects}, 10_000)
        catch
          :exit, _ ->
            # The bot process died mid-apply; the bot will resend the
            # delivery_result (at-least-once) and a fresh process handles it.
            BotGateway.build_delivery_ack(delivery_id, "failed", %{
              "error" => %{"code" => "BOT_EFFECT_INVALID", "message" => "unknown delivery_id"}
            })
        end
    end
  end

  # -------------------------------------------------------------- push frame

  @doc """
  Push a `delivery` frame to the bot (from the commit hot path).
  Returns `:ok` (pushed, or the row stays pending for resume) or `:offline`.
  """
  def push_frame(bot_id, frame) do
    case pid_for(bot_id) do
      nil ->
        :offline

      pid ->
        try do
          GenServer.call(pid, {:push_frame, frame}, 1_000)
        catch
          :exit, _ -> :offline
        end
    end
  end

  # --------------------------------------------------------------- detach

  @doc """
  Handle WS close (or lease expiry / crash): clear the session and arm the
  offline TTL timer.

  `session_id` (optional) guards against a stale socket evicting a newer
  session: when given, the detach only applies if it still matches the
  current session (old Worker
  `markDisconnectedIfCurrentAttachment` parity).
  """
  def detach(bot_id, reason \\ :ws_close, session_id \\ nil) do
    if pid = pid_for(bot_id) do
      GenServer.cast(pid, {:detach, reason, session_id})
    end

    :ok
  end

  # --------------------------------------------------------- server callbacks

  @impl true
  def init(bot_id) do
    # The process is started with a Registry `via` name (bot_id → pid),
    # so lookup/cleanup of the connection handle is automatic.

    state = %{
      bot_id: bot_id,
      channel_pid: nil,
      session_id: nil,
      lease_ref: nil,
      offline_ref: nil,
      offline_reschedules: 0
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(:online?, _from, state), do: {:reply, state.channel_pid != nil, state}

  def handle_call({:connect, channel_pid, last_received}, _from, state) do
    session_id = Ids.uuidv7()

    # `resume_frames/1` accounts the redelivery as an attempt (and enforces
    # `max_attempts`) while building the frames.
    frames = BotDelivery.resume_frames(state.bot_id)

    state =
      state
      |> Map.put(:channel_pid, channel_pid)
      |> Map.put(:session_id, session_id)
      # Stored for observability only — not a resume skip boundary
      # (see `connect/3` moduledoc; old-Worker parity).
      |> Map.put(:last_received_delivery_id, last_received)
      |> Map.put(:offline_ref, cancel(state.offline_ref))
      |> Map.put(:offline_reschedules, 0)
      |> schedule_lease()

    reply = %{
      ready: BotGateway.build_ready(state.bot_id, session_id),
      frames: frames
    }

    {:reply, reply, state}
  end

  def handle_call({:deliver_result, delivery_id, effects}, _from, state) do
    ack = BotDelivery.apply_result(state.bot_id, delivery_id, effects)
    {:reply, ack, state |> schedule_lease()}
  end

  def handle_call({:push_frame, frame}, _from, state) do
    if state.channel_pid == nil do
      {:reply, :offline, state}
    else
      push(state.channel_pid, frame)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, state |> schedule_lease()}
  end

  def handle_cast({:detach, reason, session_id}, state) do
    if is_nil(session_id) or state.session_id == session_id do
      Logger.debug("bot connection detached (#{reason}): #{state.bot_id}")
      {:noreply, do_detach(state, reason)}
    else
      # A stale socket closing after the bot reconnected (its session was
      # replaced by a newer hello) must not evict the live connection —
      # old Worker `markDisconnectedIfCurrentAttachment` parity.
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:lease_expired, state) do
    if state.session_id == nil do
      {:noreply, state}
    else
      # Contract §9.7.1: lease expiry → server closes the bot WS
      # (reason `lease_expired`). Phoenix Channels has no stable
      # server-initiated close API yet; the bot notices via its own WS
      # timeout and reconnects (the session is already marked offline, so
      # pending rows survive for resume).
      notify_channel(state.channel_pid, %{
        "type" => "lease_expired",
        "api_version" => BotGateway.api_version()
      })

      {:noreply, do_detach(state, :lease_expired)}
    end
  end

  def handle_info(:offline_expiry, state) do
    BotDelivery.expire_offline(state.bot_id)

    if BotDelivery.pending_count(state.bot_id) > 0 and
         state.offline_reschedules < 3 do
      ref = Process.send_after(self(), :offline_expiry, config(:offline_ttl_ms, 30_000))

      {:noreply,
       %{
         state
         | offline_ref: ref,
           offline_reschedules: state.offline_reschedules + 1
       }}
    else
      {:noreply, state}
    end
  end

  # --------------------------------------------------------------- internals

  defp do_detach(state, _reason) do
    state =
      state
      |> Map.put(:channel_pid, nil)
      |> Map.put(:session_id, nil)
      |> Map.put(:lease_ref, cancel(state.lease_ref))

    if BotDelivery.pending_count(state.bot_id) > 0 do
      ref = Process.send_after(self(), :offline_expiry, config(:offline_ttl_ms, 30_000))
      Map.put(state, :offline_ref, ref)
    else
      state
    end
  end

  defp schedule_lease(state) do
    cancel(state.lease_ref)

    ref = Process.send_after(self(), :lease_expired, config(:lease_ttl_ms, 60_000))

    Map.put(state, :lease_ref, ref)
  end

  defp push(channel_pid, frame) do
    send(channel_pid, {:bot_ws_push, frame})
  end

  defp notify_channel(nil, _frame), do: :ok

  defp notify_channel(pid, frame) do
    if Process.alive?(pid) do
      send(pid, {:bot_ws_notify, frame})
    end
  end

  # Idempotent: the ref is stored back in state and may be cancelled again
  # (an already-fired / already-cancelled ref is a no-op).
  defp cancel(ref) do
    if is_reference(ref) do
      Process.cancel_timer(ref, async: false)
    end

    ref
  end

  defp config(key, default) do
    Application.get_env(:lilium_chat, :bot_gateway, [])
    |> Keyword.get(key, default)
  end

  defp pid_for(bot_id) do
    # `Registry.lookup/2` returns a list: `[]` when absent.
    case Registry.lookup(LiliumChat.Bots.Registry, bot_id) do
      [] -> nil
      [{pid, _}] -> pid
    end
  end

  defp pid_for!(bot_id) do
    {:ok, pid} = ensure_started(bot_id)
    pid
  end

  defp via_registry(key) do
    # 2-tuple form: the registry key IS the bot_id (the 3-tuple form would
    # treat the 2nd element as the key and the bot_id as metadata).
    {:via, Registry, {LiliumChat.Bots.Registry, key}}
  end
end
