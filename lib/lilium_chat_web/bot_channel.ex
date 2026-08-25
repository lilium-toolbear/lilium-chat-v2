defmodule LiliumChatWeb.BotChannel do
  @moduledoc """
  Bot Gateway WebSocket channel (contract §9.7, issue #17).

  One channel per bot socket, topic `bot:<bot_id>` (the bot must join its
  own topic — the topic id is matched against the token-authenticated
  bot identity from `BotSocket.connect/3`).

  ## Frames (client → server, via `handle_in/3`)

  * `hello` — handshake; reply `ready` (`session_id`), then push every
    `pending` `delivery` frame in `delivery_id` order (crash recovery /
    resume, spec D14 — the bot dedupes on `delivery_id`).
  * `ping` — lease refresh; reply `pong`.
  * `delivery_result` — effect application (idempotent per
    `(channel_id, bot_id, client_effect_id)`); reply `delivery_ack`.

  Malformed frames are logged and swallowed (old Worker parity: the bot
  keeps the socket open and may retry).

  ## Server → client (via `handle_info/2`)

  * `{:bot_ws_push, frame}` — a `delivery` frame pushed by the commit hot
    path (from the `Bot.<bot_id>` process).
  * `{:bot_ws_notify, frame}` — informational frames (lease expiry).
  """

  use Phoenix.Channel

  require Logger

  alias LiliumChat.{BotConnection, BotGateway}

  # ------------------------------------------------------------------- join

  @impl true
  def join("bot:" <> bot_id, _payload, socket) do
    case fetch_identity(socket) do
      %{bot_id: ^bot_id} ->
        {:ok, %{}, assign(socket, :bot_id, bot_id)}

      _identity ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "bad_topic"}}
  end

  # ------------------------------------------------------------- handle_in

  @impl true
  def handle_in("hello", payload, socket) do
    case BotGateway.parse_hello(payload) do
      {:ok, last_received} ->
        %{ready: ready, frames: frames} =
          BotConnection.connect(socket.assigns[:bot_id], self(), last_received)

        # The reply (ready) is flushed first; the resume delivery frames
        # are pushed from the follow-up handle_info so the client always
        # sees `ready` before any `delivery`.
        if frames != [] do
          send(self(), {:push_resume, frames})
        end

        # Remember this session so `terminate/2` can guard the detach: a
        # stale socket closing after the bot reconnected must not evict
        # the live session.
        {:reply, {:ok, ready}, assign(socket, :session_id, ready["session_id"])}

      {:error, reason} ->
        Logger.debug("bot hello rejected for #{socket.assigns[:bot_id]}: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_in("ping", _payload, socket) do
    BotConnection.touch(socket.assigns[:bot_id])
    {:reply, {:ok, BotGateway.build_pong()}, socket}
  end

  def handle_in("delivery_result", payload, socket) do
    case BotGateway.parse_delivery_result(payload) do
      {:ok, %{delivery_id: delivery_id, effects: effects}} ->
        ack = BotConnection.deliver_result(socket.assigns[:bot_id], delivery_id, effects)
        {:reply, {:ok, ack}, socket}

      {:error, reason} ->
        Logger.debug("bot delivery_result rejected for #{socket.assigns[:bot_id]}: #{reason}")

        {:noreply, socket}
    end
  end

  def handle_in("session.effects", payload, socket) do
    case BotGateway.parse_session_effects(payload) do
      {:ok, parsed} ->
        ack =
          BotConnection.deliver_session_effects(
            socket.assigns[:bot_id],
            parsed
          )

        {:reply, {:ok, ack}, socket}

      {:error, reason} ->
        Logger.debug("bot session.effects rejected for #{socket.assigns[:bot_id]}: #{reason}")
        {:noreply, socket}
    end
  end

  # `session.close` / `session.input_ack` / `session.start_ack` are SILENT
  # acks (old-Worker parity, contract §9.7.4): the old Worker's
  # BotConnection sends no bot-visible reply for them — the bot learns the
  # outcome from server-pushed frames (`session.closed`, the
  # `stateful_session.*` fanout, …). A Phoenix `phx_reply` here would leak
  # the envelope onto the raw wire, because the BotSocket seam only
  # unwraps replies whose payload is a bot frame (carries `type`).
  def handle_in("session.close", payload, socket) do
    case BotGateway.parse_session_close(payload) do
      {:ok, %{session_id: session_id, reason: reason}} ->
        BotConnection.deliver_session_close(
          socket.assigns[:bot_id],
          session_id,
          reason
        )

        {:noreply, socket}

      {:error, reason} ->
        Logger.debug("bot session.close rejected for #{socket.assigns[:bot_id]}: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_in("session.input_ack", payload, socket) do
    case BotGateway.parse_session_input_ack(payload) do
      {:ok, parsed} ->
        BotConnection.deliver_session_input_ack(socket.assigns[:bot_id], parsed)
        {:noreply, socket}

      {:error, reason} ->
        Logger.debug("bot session.input_ack rejected for #{socket.assigns[:bot_id]}: #{reason}")

        {:noreply, socket}
    end
  end

  # `session.start_ack` (issue #20): the bot accepted a `session.start` —
  # the channel writer activates the session + creates the session-control
  # pin.
  def handle_in("session.start_ack", payload, socket) do
    case BotGateway.parse_session_start_ack(payload) do
      {:ok, parsed} ->
        BotConnection.deliver_session_start_ack(socket.assigns[:bot_id], parsed)
        {:noreply, socket}

      {:error, reason} ->
        Logger.debug("bot session.start_ack rejected for #{socket.assigns[:bot_id]}: #{reason}")

        {:noreply, socket}
    end
  end

  def handle_in(event, _payload, socket) do
    Logger.debug("BotChannel unhandled frame type: #{event}")
    {:noreply, socket}
  end

  # --------------------------------------------------------- handle_info

  @impl true
  def handle_info({:push_resume, frames}, socket) do
    # Delivery resume frames carry no `type` (pushed as `delivery`); the
    # unacked `session.input` frames resume after them (old Worker
    # `resumeStatefulSessions` order) and keep their frame type.
    Enum.each(frames, fn frame -> push(socket, frame["type"] || "delivery", frame) end)
    {:noreply, socket}
  end

  def handle_info({:bot_ws_push, %{} = frame}, socket) do
    push(socket, frame["type"] || "delivery", frame)
    {:noreply, socket}
  end

  def handle_info({:bot_ws_notify, %{} = frame}, socket) do
    push(socket, frame["type"] || "notify", frame)
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -------------------------------------------------------------- terminate

  @impl true
  def terminate(_reason, socket) do
    if bot_id = socket.assigns[:bot_id] do
      # Session-guarded: a stale socket closing after the bot reconnected
      # must not evict the live session (old Worker
      # markDisconnectedIfCurrentAttachment parity).
      BotConnection.detach(bot_id, :ws_close, socket.assigns[:session_id])
    end

    :ok
  end

  # -------------------------------------------------------------- helpers

  # In production the bot identity lives in the Phoenix.Socket assigns
  # (set by BotSocket.connect/3); in ChannelTest the test socket carries
  # assigns directly (same pattern as BrowserChannel).
  defp fetch_identity(socket) do
    case Map.get(socket, :socket) do
      %Phoenix.Socket{assigns: assigns} ->
        assigns[:bot_identity]

      _ ->
        socket.assigns[:bot_identity]
    end
  end
end
