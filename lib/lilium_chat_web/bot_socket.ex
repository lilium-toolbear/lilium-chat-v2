defmodule LiliumChatWeb.BotSocket do
  @moduledoc """
  Bot Gateway WebSocket socket (contract §9.7 / §9.1, issue #17).

  Served at `/api/chat/bot/ws` via the Phoenix endpoint. The bot connects
  with the `lilium.chat.bot.v1` subprotocol and authenticates with a bot
  token (`Authorization: Bearer <token>` per the contract).

  Handshake validation (split between transport + this socket):

  * **Subprotocol** — the transport validates `lilium.chat.bot.v1` is
    present in `Sec-WebSocket-Protocol` (via the `subprotocols` option)
    and echoes it back.
  * **Origin** — checked by the transport via `check_origin` (CORS
    whitelist). Non-browser bot runtimes send no `Origin` header, which
    the transport accepts.
  * **Token + scope** — this socket's `connect/3` extracts the bot token
    and verifies it with `LiliumChat.BotTokens.verify/1` (same rules as
    the HTTP Bot AuthPlug, spec §6.1), then requires the
    `chat:runtime:connect` scope.

  Token transport: the contract's primary carrier is the `Authorization`
  header, which Phoenix's `connect_info` does not surface. This socket
  therefore accepts the token through the same subprotocol convention the
  Browser socket uses for JWTs (`bearer.<token>` entry in
  `Sec-WebSocket-Protocol`) and, as a fallback, the `?token=` query
  parameter. Both are equivalent transports for the same bearer token.

  Connect failures render the contract error envelope with the exact
  HTTP status (401 `UNAUTHORIZED` missing/invalid token, 403 `FORBIDDEN`
  missing scope) via the endpoint `error_handler` option
  (`handle_connect_error/2`).

  ## Raw-frame protocol (contract §9.7, issue #27)

  The contract wire protocol is **raw JSON frames**: after the WS
  handshake the bot sends `{"type": ..., "api_version": ...}` frames and
  receives raw `ready` / `delivery` / `delivery_ack` / `session.*`
  frames — it does **not** speak Phoenix Channels (no join, no `phx_*`
  envelopes). Same transport seam as `BrowserSocket`:

  * `handle_in/2` (overridden) routes inbound raw frames into a
    lazily-joined `BotChannel` process (one per socket) with
    `event = frame["type"]`; Phoenix-format frames fall through to the
    standard `Phoenix.Socket` dispatch unchanged.
  * `handle_info/2` (overridden) unwraps outbound Phoenix frames back
    into raw frames: a `phx_reply` whose response is a bot frame, and any
    push whose payload is a bot frame, cross the wire as the bare frame.
  """

  require Logger

  alias LiliumChat.{BotGateway, BotTokens, Errors}
  alias LiliumChatWeb.{BotChannel, ErrorHandler}
  alias Phoenix.Socket.Message

  # ------------------------------------------------------ transport seams
  #
  # Defined BEFORE `use Phoenix.Socket` so these clauses are registered
  # first and win over the macro-generated catch-alls (the macro's own
  # `handle_in/2` / `handle_info/2` clauses, defined at `use`, stay the
  # fallback for Phoenix-format messages).

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

  channel "bot:*", LiliumChatWeb.BotChannel

  @connect_scope "chat:runtime:connect"

  @impl true
  def connect(params, socket, connect_info) do
    sec_headers = connect_info[:sec_websocket_headers] || []

    with {:ok, token} <- extract_token(params, sec_headers),
         {:ok, identity} <- BotTokens.verify(token) do
      if @connect_scope in identity.scopes do
        # Spec §10 WS 连接数 gauge (issue #21): SocketTracker monitors this
        # process and decrements when it terminates.
        LiliumChat.Observability.track_socket(:bot)
        {:ok, assign(socket, :bot_identity, identity)}
      else
        {:error, Errors.new("FORBIDDEN", "Missing scope: #{@connect_scope}")}
      end
    else
      {:error, %Errors.ApiError{} = api_error} ->
        {:error, api_error}

      {:error, reason} ->
        {:error, Errors.new("UNAUTHORIZED", to_string(reason))}
    end
  end

  @impl true
  def id(_socket), do: nil

  @doc """
  Transport `error_handler`: render a failed `connect/3` as the contract
  error envelope with the ApiError's HTTP status (401/403).
  """
  def handle_connect_error(conn, %Errors.ApiError{} = api_error) do
    conn |> ErrorHandler.render(api_error)
  end

  def handle_connect_error(conn, reason) do
    conn
    |> ErrorHandler.render(Errors.new("UNAUTHORIZED", to_string(reason)))
  end

  # ------------------------------------------------------------- internals

  defp dispatch_raw_frame(state, socket, raw_frame) do
    bot_id = socket.assigns[:bot_identity].bot_id
    topic = "bot:#{bot_id}"

    case socket.assigns[:bot_channel_pid] do
      pid when is_pid(pid) ->
        send_bot_frame(pid, topic, raw_frame)
        {:ok, {state, socket}}

      _ ->
        case join_bot_channel(socket, topic) do
          {:ok, pid} ->
            send_bot_frame(pid, topic, raw_frame)
            {:ok, {state, assign(socket, :bot_channel_pid, pid)}}

          {:error, reason} ->
            # The socket is connected (token verified) but the channel
            # session could not be started — answer so the transport stays
            # up (a raise here closes the socket with 1011).
            Logger.warning("bot channel join failed: #{inspect(reason)}")
            raw_frame_error(state, socket, raw_frame)
        end
    end
  end

  defp raw_frame_error(state, socket, raw_frame) do
    case raw_frame["type"] do
      "hello" ->
        push_raw(
          state,
          socket,
          BotGateway.build_ready(socket.assigns[:bot_identity].bot_id, "session")
        )

      "ping" ->
        push_raw(state, socket, BotGateway.build_pong())

      _ ->
        push_raw(
          state,
          socket,
          BotGateway.build_delivery_ack(
            raw_frame["delivery_id"] || "unknown",
            "failed",
            %{
              "error" => %{
                "code" => "CHAT_WORKER_UNAVAILABLE",
                "message" => "bot session temporarily unavailable",
                "retryable" => true
              }
            }
          )
        )
    end
  end

  defp join_bot_channel(socket, topic) do
    message = %Message{
      topic: topic,
      event: "phx_join",
      payload: %{},
      ref: "bot-auto-join",
      join_ref: "bot-auto-join"
    }

    case Phoenix.Channel.Server.join(socket, BotChannel, message, []) do
      {:ok, _reply, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_bot_frame(pid, topic, raw_frame) do
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

  defp push_raw(state, socket, frame) do
    send(self(), {:socket_push, :text, Phoenix.json_library().encode_to_iodata!(frame)})
    {:ok, {state, socket}}
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

  defp extract_token(params, sec_headers) do
    case subprotocol_token(sec_headers) || query_token(params) do
      nil ->
        {:error, "Not authenticated"}

      token ->
        {:ok, token}
    end
  end

  # `bearer.<token>` entry in Sec-WebSocket-Protocol (Browser-WS convention).
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
