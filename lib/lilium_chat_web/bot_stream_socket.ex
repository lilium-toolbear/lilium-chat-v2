defmodule LiliumChatWeb.BotStreamSocket do
  @moduledoc """
  Bot Stream WebSocket socket (contract §9.15 / issue #18).

  Served at `/api/chat/bot/channels/:channel_id/streams/:message_id/ws`.
  Subprotocol `lilium.chat.bot.stream.v1`. Auth is the same Chat Bot
  Token as the main gateway (no dedicated stream token) and requires
  both `chat:runtime:connect` and `chat:messages:write`.

  Upgrade checks mirror the old Worker route order (contract §9.15.1):
  token → scopes → **stream-registry check** (owner + status/expiry),
  so the connect response already carries `BOT_STREAM_NOT_FOUND` (404)
  / `BOT_STREAM_EXPIRED` (410) parity.

  Like `BotSocket`, a raw-frame transport seam (declared BEFORE
  `use Phoenix.Socket`) routes contract frames (`{"type": ...}`) into a
  lazily-joined `BotStreamChannel` and unwraps channel replies/pushes
  back to bare frames.
  """

  @impl true
  def handle_in({payload, opts}, {state, socket}) do
    case Phoenix.json_library().decode(payload) do
      {:ok, %{} = decoded} ->
        if raw_frame_in?(decoded) do
          dispatch_raw_frame(state, socket, decoded)
        else
          Phoenix.Socket.__in__({payload, opts}, {state, socket})
        end

      _ ->
        Phoenix.Socket.__in__({payload, opts}, {state, socket})
    end
  end

  @impl true
  def handle_info({:socket_push, opcode, payload} = message, state) do
    case raw_frame_from_wire(payload) do
      {:raw, frame} ->
        {:push, {opcode, Phoenix.json_library().encode_to_iodata!(frame)}, state}

      :pass ->
        Phoenix.Socket.__info__(message, state)
    end
  end

  use Phoenix.Socket

  channel "stream:*", LiliumChatWeb.BotStreamChannel

  require Logger

  alias LiliumChat.{BotStream, BotTokens, Errors, Stream}
  alias LiliumChatWeb.{BotStreamChannel, ErrorHandler}
  alias Phoenix.Socket.Message

  @impl true
  def connect(params, socket, connect_info) do
    sec_headers = connect_info[:sec_websocket_headers] || []

    with {:ok, token} <- extract_token(params, sec_headers),
         {:ok, identity} <- BotTokens.verify(token),
         :ok <- require_scopes(identity),
         {:ok, channel_id, message_id} <- path_ids(params),
         :ok <- registry_check(channel_id, message_id, identity.bot_id) do
      # Spec §10 WS 连接数 gauge (issue #21): SocketTracker monitors this
      # process and decrements when it terminates.
      LiliumChat.Observability.track_socket(:bot_stream)

      {:ok,
       socket
       |> assign(:bot_identity, identity)
       |> assign(:channel_id, channel_id)
       |> assign(:message_id, message_id)}
    else
      {:error, %Errors.ApiError{} = api_error} ->
        {:error, api_error}

      {:error, reason} ->
        {:error, Errors.new("UNAUTHORIZED", to_string(reason))}
    end
  end

  @impl true
  def id(_socket), do: nil

  def handle_connect_error(conn, %Errors.ApiError{} = api_error) do
    conn |> ErrorHandler.render(api_error)
  end

  def handle_connect_error(conn, reason) do
    conn
    |> ErrorHandler.render(Errors.new("UNAUTHORIZED", to_string(reason)))
  end

  # ------------------------------------------------------------- internals

  defp dispatch_raw_frame(state, socket, raw_frame) do
    channel_id = socket.assigns[:channel_id]
    message_id = socket.assigns[:message_id]
    topic = "stream:#{channel_id}##{message_id}"

    case socket.assigns[:bot_stream_channel_pid] do
      pid when is_pid(pid) ->
        send_stream_frame(pid, topic, raw_frame)
        {:ok, {state, socket}}

      _ ->
        case join_stream_channel(socket, topic) do
          {:ok, pid} ->
            send_stream_frame(pid, topic, raw_frame)
            {:ok, {state, assign(socket, :bot_stream_channel_pid, pid)}}

          {:error, reason} ->
            # The socket is connected (token + registry verified) but the
            # channel session could not be started — answer with a
            # `stream_error` so the transport stays up (a raise here
            # closes the socket with 1011).
            Logger.warning("bot stream channel join failed: #{inspect(reason)}")
            raw_stream_error(state, socket, raw_frame)
        end
    end
  end

  defp raw_stream_error(state, socket, _raw_frame) do
    frame = BotStream.build_error(Errors.new("BOT_STREAM_NOT_FOUND", "stream not active"))

    send(self(), {:socket_push, :text, Phoenix.json_library().encode_to_iodata!(frame)})
    {:ok, {state, socket}}
  end

  defp join_stream_channel(socket, topic) do
    message = %Message{
      topic: topic,
      event: "phx_join",
      payload: %{},
      ref: "bot-stream-auto-join",
      join_ref: "bot-stream-auto-join"
    }

    case Phoenix.Channel.Server.join(socket, BotStreamChannel, message, []) do
      {:ok, _reply, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_stream_frame(pid, topic, raw_frame) do
    send(
      pid,
      %Message{
        topic: topic,
        event: raw_frame["type"],
        payload: raw_frame,
        ref: "raw-#{System.unique_integer([:positive])}"
      }
    )
  end

  # A `phx_reply` whose response is a bot frame, or a push whose payload is
  # a bot frame, crosses the wire as the bare frame.
  defp raw_frame_from_wire(payload) do
    case Phoenix.json_library().decode(payload) do
      {:ok, %{"event" => "phx_reply", "payload" => %{"response" => response}}} ->
        if raw_frame_map?(response), do: {:raw, response}, else: :pass

      {:ok, %{"event" => _event, "payload" => payload}} when is_map(payload) ->
        if raw_frame_map?(payload), do: {:raw, payload}, else: :pass

      _ ->
        :pass
    end
  end

  defp raw_frame_map?(map), do: is_map(map) and is_map_key(map, "type")

  # Inbound: a contract frame carries a binary `"type"` (and `api_version`)
  # at the top level; Phoenix messages carry `"topic"`/`"event"` instead.
  defp raw_frame_in?(%{"type" => type} = frame) when is_binary(type) do
    not Map.has_key?(frame, "topic")
  end

  defp raw_frame_in?(_), do: false

  # Old Worker `streamRegistryCheck` parity (contract §9.15.1): the
  # registry must contain the stream, owned by this bot, still `streaming`
  # and unexpired — otherwise the upgrade itself fails (404/410).
  defp registry_check(channel_id, message_id, bot_id) do
    case Stream.lookup(channel_id, message_id) do
      {:ok, %{bot_id: ^bot_id, status: "streaming", expires_at: expires_at}} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          {:error, Errors.new("BOT_STREAM_EXPIRED", "stream registry expired")}
        else
          :ok
        end

      {:ok, %{status: "finalized"}} ->
        {:error, Errors.new("BOT_STREAM_EXPIRED", "stream registry expired")}

      {:ok, %{status: "abandoned"}} ->
        {:error, Errors.new("BOT_STREAM_EXPIRED", "stream registry expired")}

      {:ok, _other} ->
        # owner mismatch (or unknown status) — old Worker 404s before any
        # status distinction.
        {:error, Errors.new("BOT_STREAM_NOT_FOUND", "stream registry not found")}

      {:error, _} ->
        {:error, Errors.new("BOT_STREAM_NOT_FOUND", "stream registry not found")}
    end
  end

  defp require_scopes(identity) do
    missing =
      Enum.reject(BotStream.connect_scopes(), fn scope -> scope in identity.scopes end)

    case missing do
      [] ->
        :ok

      [scope | _] ->
        {:error, Errors.new("BOT_SCOPE_DENIED", "Missing scope: #{scope}")}
    end
  end

  defp path_ids(params) do
    case {params["channel_id"], params["message_id"]} do
      {cid, mid} when is_binary(cid) and cid != "" and is_binary(mid) and mid != "" ->
        {:ok, cid, mid}

      _ ->
        {:error, Errors.new("BOT_STREAM_NOT_FOUND", "stream registry not found")}
    end
  end

  defp extract_token(params, sec_headers) do
    case subprotocol_token(sec_headers) || query_token(params) do
      nil -> {:error, "Not authenticated"}
      token -> {:ok, token}
    end
  end

  defp subprotocol_token(sec_headers) do
    case List.keyfind(sec_headers, "sec-websocket-protocol", 0) do
      {"sec-websocket-protocol", header} ->
        header
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.find_value(fn
          "bearer." <> token when token != "" -> token
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp query_token(params) do
    case params do
      %{"token" => token} when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end
end
