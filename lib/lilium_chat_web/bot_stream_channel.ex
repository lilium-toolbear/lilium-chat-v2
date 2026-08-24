defmodule LiliumChatWeb.BotStreamChannel do
  @moduledoc """
  Bot Stream WebSocket channel (contract §9.15, issue #18).

  One channel per stream socket, topic `stream:<channel_id>#<message_id>`.
  The bot must join the topic that matches the path ids captured at
  socket connect, and the token-authenticated bot must own the stream.

  Frames (client → server via `handle_in/3`):

  * `hello` — handshake; reply `ready` (`ack_seq`, `expires_at`)
  * `append` — seq/ack; `append_ack` is pushed after durable flush
  * `finalize` — reply `finalized_ack` (idempotent) or `stream_error`
  * `ping` — reply `pong`

  Malformed frames are swallowed (old Worker parity).
  """

  use Phoenix.Channel

  require Logger

  alias LiliumChat.{BotStream, Stream}

  @impl true
  def join("stream:" <> rest, _payload, socket) do
    expected = "#{socket.assigns[:channel_id]}##{socket.assigns[:message_id]}"
    identity = fetch_identity(socket)

    cond do
      rest != expected ->
        {:error, %{reason: "unauthorized"}}

      is_nil(identity) ->
        {:error, %{reason: "unauthorized"}}

      true ->
        case Stream.owner(socket.assigns[:channel_id], socket.assigns[:message_id]) do
          {:ok, bot_id} when bot_id == identity.bot_id ->
            {:ok, %{}, assign(socket, :bot_id, identity.bot_id)}

          {:ok, _} ->
            {:error, %{reason: "unauthorized"}}

          {:error, _} ->
            {:error, %{reason: "not_found"}}
        end
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "bad_topic"}}

  # ------------------------------------------------------------- handle_in

  @impl true
  def handle_in("hello", payload, socket) do
    case BotStream.parse_hello(payload) do
      {:ok, _} ->
        case Stream.attach(socket.assigns.channel_id, socket.assigns.message_id, self()) do
          {:ok, ready} ->
            {:reply, {:ok, BotStream.build_ready(ready)}, socket}

          {:error, error} ->
            {:reply, {:error, BotStream.build_error(error)}, socket}
        end

      {:error, reason} ->
        Logger.debug("stream hello rejected: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_in("ping", payload, socket) do
    case BotStream.parse_ping(payload) do
      {:ok, _} -> {:reply, {:ok, BotStream.build_pong()}, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_in("append", payload, socket) do
    case BotStream.parse_append(payload) do
      {:ok, %{seq: seq, delta: delta}} ->
        case Stream.append(socket.assigns.channel_id, socket.assigns.message_id, seq, delta) do
          {:ok, :accepted} ->
            {:noreply, socket}

          {:ok, :unacked_duplicate} ->
            {:noreply, socket}

          {:ok, {:durable_noop, ack_seq}} ->
            {:reply, {:ok, BotStream.build_append_ack(ack_seq)}, socket}

          {:error, error} ->
            {:reply, {:error, BotStream.build_error(error)}, socket}
        end

      {:error, reason} ->
        Logger.debug("stream append rejected: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_in("finalize", payload, socket) do
    case BotStream.parse_finalize(payload) do
      {:ok, parsed} ->
        frame = %{
          "final_seq" => parsed.final_seq,
          "components" => parsed.components,
          "attachment_ids" => parsed.attachment_ids
        }

        case Stream.finalize(socket.assigns.channel_id, socket.assigns.message_id, frame) do
          {:ok, result} ->
            {:reply,
             {:ok, BotStream.build_finalized_ack(result["message_id"], result["event_id"])},
             socket}

          {:error, error} ->
            {:reply, {:error, BotStream.build_error(error)}, socket}
        end

      {:error, reason} ->
        Logger.debug("stream finalize rejected: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_in(event, _payload, socket) do
    Logger.debug("BotStreamChannel unhandled frame type: #{event}")
    {:noreply, socket}
  end

  # --------------------------------------------------------- handle_info

  @impl true
  def handle_info({:stream_push, %{} = frame}, socket) do
    push(socket, frame["type"] || "append_ack", frame)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------- helpers

  defp fetch_identity(socket) do
    case Map.get(socket, :socket) do
      %Phoenix.Socket{assigns: assigns} -> assigns[:bot_identity]
      _ -> socket.assigns[:bot_identity]
    end
  end
end
