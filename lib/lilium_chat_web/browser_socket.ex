defmodule LiliumChatWeb.BrowserSocket do
  @moduledoc """
  Browser WebSocket socket (contract §2.1 / §10.1, issue #8).

  Served at `/api/chat/ws` via the Phoenix endpoint. The client connects with:

      new WebSocket("wss://chat.kuma.homes/api/chat/ws", [
        "lilium.chat.v2",
        "bearer.<toolbear_browser_jwt>"
      ])

  Handshake validation (split between transport + this socket):

  * **Origin** — checked by the Phoenix transport via the `check_origin`
    websocket option (CORS whitelist from config `:lilium_chat, :cors, :origins`).
  * **Subprotocol** — the transport validates that `lilium.chat.v2` is present
    in the `Sec-WebSocket-Protocol` header (via the `subprotocols` option) and
    echoes it back in the response.
  * **JWT** — this socket's `connect/3` extracts the `bearer.<jwt>` entry
    from the `Sec-WebSocket-Protocol` header and verifies it with the same
    rules as the HTTP `AuthPlug` (spec §6.1).

  Connect only creates the session (no replay, no `?cursors=` parsing,
  no implicit subscribe — contract §10.1). Live fanout is started
  explicitly by the client's `session.live_start` command (§5.11).

  ## Raw-frame protocol (contract §10.1 / §10.4, issue #27)

  The contract wire protocol is **raw JSON frames**: after the WS handshake
  the client immediately sends `{"frame_type": "command", ...}` frames and
  receives raw `command_ack` / `command_error` / `event` frames — it does
  **not** speak Phoenix Channels (no join, no `phx_*` envelopes).

  This socket adapts Phoenix to that protocol:

  * `handle_in/2` (overridden) routes inbound raw `command` frames to a
    lazily-joined `BrowserChannel` process (one per socket). Phoenix-format
    frames (a phoenix.js client) fall through to the standard `Phoenix.Socket`
    dispatch unchanged.
  * `handle_info/2` (overridden) unwraps outbound Phoenix frames back into
    raw frames: a `phx_reply` whose response is a contract frame, and any
    push whose payload is a contract frame, are pushed as the bare frame.
    Everything else passes through untouched.

  Without this layer a raw frame crashes the transport (`%{topic: t} =
  message` in `Phoenix.Socket.__in__/2` — the frame has no `topic`), which
  surfaced as a 1011 close two milliseconds after the first client frame.
  """

  alias LiliumChat.Auth
  alias LiliumChat.WebSockets.Frames
  alias Phoenix.Socket.Message

  require Logger

  # ------------------------------------------------------ transport seams
  #
  # Defined BEFORE `use Phoenix.Socket` so these clauses are registered
  # first and win over the macro-generated catch-alls (the macro's own
  # `handle_in/2` / `handle_info/2` clauses, defined at `use`, stay the
  # fallback for Phoenix-format messages).

  @impl true
  def handle_in({payload, opts}, {state, socket}) do
    case Phoenix.json_library().decode(payload) do
      {:ok, %{"frame_type" => "command"} = raw_frame} ->
        dispatch_raw_command(state, socket, raw_frame)

      _ ->
        Phoenix.Socket.__in__({payload, opts}, {state, socket})
    end
  end

  @impl true
  def handle_info({:socket_push, opcode, payload} = message, state) do
    case raw_frame_from_wire(payload) do
      {:raw, frame} ->
        # Contract §10.4 EventEnvelope has no `membership_version_at_event`
        # field — the frame carries it in-process for the D8 membership gate
        # (checked in BrowserChannel BEFORE this push); strip it for the wire
        # so the browser sees exactly the contract envelope.
        frame = strip_mv_for_wire(frame)
        {:push, {opcode, Phoenix.json_library().encode_to_iodata!(frame)}, state}

      :pass ->
        Phoenix.Socket.__info__(message, state)
    end
  end

  use Phoenix.Socket

  channel "browser:*", LiliumChatWeb.BrowserChannel

  # ------------------------------------------------------------- internals

  @impl true
  def connect(_params, socket, connect_info) do
    sec_headers = connect_info[:sec_websocket_headers] || []

    with {:ok, token} <- extract_bearer_token(sec_headers),
         {:ok, identity} <- Auth.verify(token, jwt_secret()) do
      # Spec §10 WS 连接数 gauge (issue #21): SocketTracker monitors this
      # process and decrements when it terminates.
      LiliumChat.Observability.track_socket(:browser)
      {:ok, assign(socket, :identity, identity)}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def id(_socket), do: nil

  # ------------------------------------------------- raw command dispatch

  defp dispatch_raw_command(state, socket, raw_frame) do
    command_id = raw_frame["command_id"]

    case socket.assigns[:browser_channel_pid] do
      pid when is_pid(pid) ->
        send_command(pid, socket, raw_frame)
        {:ok, {state, socket}}

      _ ->
        case socket.assigns[:identity] do
          # connect/3 always assigns identity on a connected socket; a
          # missing one is an internal state bug — answer without raising
          # (a raise here would close the transport with 1011).
          nil ->
            raw_command_error(state, socket, command_id)

          identity ->
            case join_browser_channel(socket, "browser:#{identity.user_id}") do
              {:ok, pid} ->
                send_command(pid, socket, raw_frame)
                {:ok, {state, assign(socket, :browser_channel_pid, pid)}}

              {:error, reason} ->
                # The socket is connected (JWT valid) but its channel
                # session could not be started — answer with a raw
                # command_error so the transport stays up (a crash here
                # closes the socket with 1011).
                Logger.warning("browser channel join failed: #{inspect(reason)}")
                raw_command_error(state, socket, command_id)
            end
        end
    end
  end

  defp raw_command_error(state, socket, command_id) do
    error =
      Frames.command_error(command_id || "unknown", %{
        code: "CHAT_WORKER_UNAVAILABLE",
        message: "browser session temporarily unavailable",
        retryable: true
      })

    send(self(), {:socket_push, :text, Phoenix.json_library().encode_to_iodata!(error)})
    {:ok, {state, socket}}
  end

  defp join_browser_channel(socket, topic) do
    message = %Message{
      topic: topic,
      event: "phx_join",
      payload: %{},
      ref: "browser-auto-join",
      join_ref: "browser-auto-join"
    }

    case Phoenix.Channel.Server.join(socket, LiliumChatWeb.BrowserChannel, message, []) do
      {:ok, _reply, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_command(pid, socket, raw_frame) do
    user_id = socket.assigns[:identity].user_id

    send(
      pid,
      %Message{
        topic: "browser:#{user_id}",
        event: "command",
        payload: raw_frame,
        ref: "raw-#{System.unique_integer([:positive])}"
      }
    )
  end

  # --------------------------------------------- raw frame unwrapping

  # A `phx_reply` whose response is a contract frame, or a push whose
  # payload is a contract frame, crosses the wire as the bare frame.
  defp raw_frame_from_wire(payload) do
    case Phoenix.json_library().decode(payload) do
      {:ok, %{"event" => "phx_reply", "payload" => %{"response" => response}}} ->
        if is_map(response) and map_has_frame?(response), do: {:raw, response}, else: :pass

      {:ok, %{"event" => _event, "payload" => payload}} when is_map(payload) ->
        if map_has_frame?(payload), do: {:raw, payload}, else: :pass

      _ ->
        :pass
    end
  end

  defp map_has_frame?(map), do: Map.has_key?(map, "frame_type")

  defp strip_mv_for_wire(%{"frame_type" => "event"} = frame),
    do: Map.delete(frame, "membership_version_at_event")

  defp strip_mv_for_wire(frame), do: frame

  # ------------------------------------------------------------- JWT (WS)

  defp extract_bearer_token(headers) do
    case find_header(headers, "sec-websocket-protocol") do
      nil ->
        {:error, "missing Sec-WebSocket-Protocol"}

      header ->
        protocols = header |> String.split(",") |> Enum.map(&String.trim/1)

        case Enum.find(protocols, &String.starts_with?(&1, "bearer.")) do
          nil ->
            {:error, "missing bearer subprotocol"}

          "bearer." <> token ->
            if token == "" do
              {:error, "empty bearer token"}
            else
              {:ok, token}
            end
        end
    end
  end

  defp find_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      _ -> nil
    end
  end

  defp jwt_secret do
    Application.get_env(:lilium_chat, :jwt)[:secret]
  end
end
