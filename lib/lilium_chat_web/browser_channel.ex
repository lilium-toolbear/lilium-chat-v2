defmodule LiliumChatWeb.BrowserChannel do
  @moduledoc """
  Browser WebSocket channel (contract §5.11 / §5.12 / §10.1–§10.5, issue #8).

  One channel per user socket, topic `browser:<user_id>`. The client joins
  after the socket connect (subprotocol + JWT) succeeds, then sends
  `session.live_start` to begin receiving live fanout for all active
  member channels.

  ## Commands (client → server, via `handle_in/3`)

  * `session.live_start` — subscribe to all active member channel topics;
    respond with `command_ack` carrying `{session_id, subscribed_channel_count, lease_expires_at}`.
  * `session.heartbeat` — refresh the live lease; respond with
    `command_ack` carrying `{session_id, lease_expires_at}`.

  ## PubSub topics (server → client, via `handle_info/2`)

  * `channel:<channel_id>` — per-channel timeline events (best-effort).
  * `user:<user_id>` — user-scoped hints (`my_channels_changed`,
    `read_state_updated`).

  ## Membership gate (spec D8 / §5.2)

  Each broadcast frame carries `membership_version_at_event`. The socket
  compares it against the ETS-cached `channels.membership_version`:

  * equal or older → deliver (fast path)
  * newer → re-check `channel_members` (SoT) before delivering; update
    cache on success
  """

  use Phoenix.Channel

  require Logger

  import Ecto.Query

  alias LiliumChat.{Errors, Ids, MembershipCache, Repo}
  alias LiliumChat.WebSockets.Frames

  # PubSub topic helpers
  @channel_topic_prefix "channel:"
  @user_topic_prefix "user:"

  # Recommended lease TTL (contract §5.12: 10 min)
  @lease_ttl_seconds 600

  # ------------------------------------------------------------------- join

  @impl true
  def join("browser:" <> _user_id, _payload, socket) do
    identity = fetch_identity(socket)

    if identity do
      socket =
        socket
        |> assign(:user_id, identity.user_id)
        |> assign(:session_id, Ids.uuidv7())
        |> assign(:live?, false)
        |> assign(:subscribed_channels, [])

      {:ok, %{}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def join(_topic, _payload, _socket) do
    {:error, %{reason: "bad_topic"}}
  end

  # ------------------------------------------------------------- handle_in

  @impl true
  def handle_in("command", payload, socket) do
    case Frames.parse_command(payload) do
      {:ok, {command, command_id, channel_id, cmd_payload}} ->
        handle_command(command, command_id, channel_id, cmd_payload, socket)

      {:error, reason} ->
        {:reply,
         {:error, Frames.command_error(payload["command_id"] || "unknown", error_from(reason))},
         socket}
    end
  end

  def handle_in(event, payload, socket) do
    Logger.debug("BrowserChannel unhandled event: #{event} #{inspect(payload)}")
    {:noreply, socket}
  end

  # --------------------------------------------------------- handle_info

  @impl true
  def handle_info({:broadcast, _topic, %{} = frame}, socket) do
    subscribed = socket.assigns[:subscribed_channels] || []
    live? = socket.assigns[:live?] == true
    joined? = Map.get(socket, :joined, true) == true

    case frame do
      # Channel event with membership gate
      %{"frame_type" => "event", "channel_id" => channel_id}
      when live? and joined? and is_binary(channel_id) ->
        if channel_id in subscribed do
          mv = mv_from_frame(frame)

          case MembershipCache.gate_check(channel_id, mv) do
            :deliver ->
              push(socket, "event", frame)

            :recheck ->
              if membership_active?(socket.assigns[:user_id], channel_id) do
                push(socket, "event", frame)
                MembershipCache.put(channel_id, mv)
              end
          end
        end

      # User-scoped frame (my_channels_changed, read_state_updated)
      %{"frame_type" => frame_type} = user_frame when live? and joined? ->
        push(socket, frame_type, user_frame)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # ------------------------------------------------------ command routing

  defp handle_command("message.send", command_id, channel_id, payload, socket) do
    user_id = socket.assigns[:user_id]

    if is_nil(channel_id) do
      # Old Worker WS path: a missing channel_id is CHANNEL_NOT_FOUND
      # ("missing channel_id"), checked before dispatching to the writer.
      {:reply,
       {:error,
        Frames.command_error(
          command_id,
          error_map(Errors.new("CHANNEL_NOT_FOUND", "missing channel_id"))
        )}, socket}
    else
      input = %{user_id: user_id, command_id: command_id, payload: payload}

      case LiliumChat.Channel.send_message(channel_id, input) do
        {:ok, ack_frame} ->
          {:reply, {:ok, ack_frame}, socket}

        {:error, %Errors.ApiError{} = api_error} ->
          {:reply, {:error, Frames.command_error(command_id, error_map(api_error))}, socket}
      end
    end
  end

  defp handle_command("session.live_start", command_id, _channel_id, _payload, socket) do
    case start_live(socket) do
      {:ok, socket, count} ->
        ack =
          Frames.command_ack("session.live_start", command_id, %{
            "session_id" => socket.assigns[:session_id],
            "subscribed_channel_count" => count,
            "lease_expires_at" => lease_expiry()
          })

        {:reply, {:ok, ack}, socket}

      {:error, code} ->
        {:reply, {:error, Frames.command_error(command_id, error_from(code))}, socket}
    end
  end

  defp handle_command("session.heartbeat", command_id, _channel_id, _payload, socket) do
    if socket.assigns[:live?] do
      ack =
        Frames.command_ack("session.heartbeat", command_id, %{
          "session_id" => socket.assigns[:session_id],
          "lease_expires_at" => lease_expiry()
        })

      {:reply, {:ok, ack}, socket}
    else
      {:reply, {:error, Frames.command_error(command_id, error_from("SESSION_NOT_LIVE"))}, socket}
    end
  end

  defp handle_command(command, command_id, _channel_id, _payload, socket) do
    Logger.debug("BrowserChannel unhandled command: #{command}")
    {:reply, {:error, Frames.command_error(command_id, error_from("INVALID_COMMAND"))}, socket}
  end

  # --------------------------------------------------------- live_start

  defp start_live(socket) do
    user_id = socket.assigns[:user_id]

    # Load all active member channels for this user
    # Returns [{channel_id, membership_version}, ...]
    channels = active_member_channels(user_id)
    channel_ids = Enum.map(channels, fn {cid, _mv} -> cid end)

    # Subscribe to PubSub topics
    for channel_id <- channel_ids do
      Phoenix.PubSub.subscribe(LiliumChat.PubSub, @channel_topic_prefix <> channel_id)
    end

    # Subscribe to user-scoped topic
    Phoenix.PubSub.subscribe(LiliumChat.PubSub, @user_topic_prefix <> user_id)

    # Cache membership versions
    for {channel_id, mv} <- channels do
      MembershipCache.put(channel_id, mv)
    end

    # Unsubscribe from previously subscribed channels (idempotent re-entry)
    for old_channel_id <- socket.assigns[:subscribed_channels] || [] do
      if old_channel_id not in channel_ids do
        Phoenix.PubSub.unsubscribe(LiliumChat.PubSub, @channel_topic_prefix <> old_channel_id)
      end
    end

    socket =
      socket
      |> assign(:live?, true)
      |> assign(:subscribed_channels, channel_ids)

    {:ok, socket, length(channel_ids)}
  rescue
    e ->
      Logger.error("live_start failed: #{Exception.message(e)}")
      {:error, "CHAT_WORKER_UNAVAILABLE"}
  end

  # ---------------------------------------------------------- membership

  defp active_member_channels(user_id) do
    query =
      from c in "channels",
        prefix: "chat_v2",
        join: m in "channel_members",
        on: m.channel_id == c.channel_id,
        prefix: "chat_v2",
        where: m.user_id == ^user_id and m.status == "active" and c.status == "active",
        select: {c.channel_id, c.membership_version}

    Repo.all(query)
  end

  defp membership_active?(user_id, channel_id) do
    query =
      from m in "channel_members",
        prefix: "chat_v2",
        where: m.user_id == ^user_id and m.channel_id == ^channel_id and m.status == "active",
        select: count(m.channel_id)

    Repo.one(query) > 0
  end

  # -------------------------------------------------------------- helpers

  # In production, the identity lives in socket.socket.assigns (set by
  # BrowserSocket.connect/3). In ChannelTest, the test socket carries
  # assigns directly on the channel socket.
  defp fetch_identity(socket) do
    case Map.get(socket, :socket) do
      %Phoenix.Socket{assigns: assigns} ->
        assigns[:identity]

      _ ->
        socket.assigns[:identity]
    end
  end

  defp mv_from_frame(%{"payload" => %{"membership_version_at_event" => mv}}), do: mv
  defp mv_from_frame(%{"membership_version_at_event" => mv}), do: mv
  defp mv_from_frame(_), do: 0

  defp lease_expiry do
    DateTime.utc_now()
    |> DateTime.add(@lease_ttl_seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp error_from(code), do: error_map(Errors.new(code))

  defp error_map(%Errors.ApiError{} = api_error) do
    %{code: api_error.code, message: api_error.message, retryable: api_error.retryable}
  end
end
