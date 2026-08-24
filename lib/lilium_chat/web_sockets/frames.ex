defmodule LiliumChat.WebSockets.Frames do
  @moduledoc """
  Browser WS frame codec (contract §10.2 / §10.4 / §5.11 / §5.12, issue #8).

  All frames are plain maps (string-keyed) ready for `Jason.encode!/1`.
  The Phoenix Channels layer wraps these as the `payload` of a channel message;
  the `event` name is the contract `frame_type`.

  Frame types (contract §10.4 / §10.5):

  * `command`          — client → server request
  * `command_ack`      — server → client committed result (payload-bearing)
  * `command_error`    — server → client protocol/business error
  * `event`            — server → client channel timeline event
  * `user_event`       — server → client user-scoped hint (not a channel event)
  * `read_state_updated` — server → client user-local read-state change
  * `stream_event`     — server → client live-only stream frame
  """

  @api_version "lilium.chat.v1"
  @stream_api_version "lilium.chat.stream.v1"

  # ---------------------------------------------------------------- commands

  @doc """
  Build a `command` frame (client → server).

  `command` is the command name (e.g. `"session.live_start"`).
  `command_id` is the client-generated durable operation id (contract §2.5).
  `channel_id` is optional (channel-scoped commands only).
  `payload` is the command-specific payload (defaults to `%{}`).
  """
  def command(command, command_id, payload \\ %{}, channel_id \\ nil) do
    base = %{
      "frame_type" => "command",
      "command" => command,
      "command_id" => command_id,
      "payload" => payload
    }

    case channel_id do
      nil -> base
      cid -> Map.put(base, "channel_id", cid)
    end
  end

  # ----------------------------------------------------------- command_ack

  @doc """
  Build a `command_ack` frame (server → client, committed).

  `payload` is the command-specific canonical result (contract §10.2):

  * `session.live_start` → `%{"session_id" => ..., "subscribed_channel_count" => ..., "lease_expires_at" => ...}`
  * `session.heartbeat`  → `%{"session_id" => ..., "lease_expires_at" => ...}`
  * `message.send` etc.  → `%{"channel_id" => ..., "event_id" => ..., "message" => ...}`
  * `channel.mark_read`  → `%{"channel_id" => ..., "last_read_event_id" => ..., "unread_count" => ...}`
  """
  def command_ack(command, command_id, payload) do
    %{
      "frame_type" => "command_ack",
      "command" => command,
      "command_id" => command_id,
      "status" => "committed",
      "payload" => payload
    }
  end

  # -------------------------------------------------------- command_error

  @doc """
  Build a `command_error` frame (server → client).

  `error` is a map with `:code`, `:message`, `:retryable` keys
  (contract §2.6 error envelope).
  """
  def command_error(command_id, %{code: code, message: message, retryable: retryable}) do
    %{
      "frame_type" => "command_error",
      "command_id" => command_id,
      "error" => %{
        "code" => code,
        "message" => message,
        "retryable" => retryable
      }
    }
  end

  # ---------------------------------------------------------------- events

  @doc """
  Build an `event` frame (server → client, channel timeline event).

  Contract §10.4 EventEnvelope:
  `frame_type`, `api_version`, `event_id`, `type`, `channel_id`,
  `occurred_at`, `payload`.
  """
  def event(event_id, type, channel_id, occurred_at, payload) do
    %{
      "frame_type" => "event",
      "api_version" => @api_version,
      "event_id" => event_id,
      "type" => type,
      "channel_id" => channel_id,
      "occurred_at" => occurred_at,
      "payload" => payload
    }
  end

  # ---------------------------------------------------------- user events

  @doc """
  Build a `user_event` frame (server → client, user-scoped hint).

  Contract §10.5: not a channel timeline event, no `event_id`.
  `event` is the hint name (e.g. `"my_channels_changed"`).
  `reason` is the trigger (e.g. `"member_added"`).
  `changed_channel_id` is the affected channel.
  """
  def user_event(event, reason, changed_channel_id) do
    %{
      "frame_type" => "user_event",
      "event" => event,
      "reason" => reason,
      "changed_channel_id" => changed_channel_id
    }
  end

  # ---------------------------------------------------- read_state_updated

  @doc """
  Build a `read_state_updated` frame (server → client, user-local).

  Contract §5.5 multi-session note: user-local state, not a channel event.
  """
  def read_state_updated(channel_id, last_read_event_id, unread_count) do
    %{
      "frame_type" => "read_state_updated",
      "channel_id" => channel_id,
      "last_read_event_id" => last_read_event_id,
      "unread_count" => unread_count
    }
  end

  # ---------------------------------------------------------- stream_event

  @doc """
  Build a `stream_event` frame (server → client, live-only stream frame).

  Contract §9.16 / wire `WireStreamEventFrame`: `type` is the live event
  name; `payload` carries `channel_id` + `message_id` (+ `delta` for
  stream_delta). Optional `stream_seq` / `occurred_at` via `opts`.
  """
  def stream_event(type, channel_id, payload, opts \\ []) when is_map(payload) do
    frame = %{
      "frame_type" => "stream_event",
      "api_version" => @stream_api_version,
      "channel_id" => channel_id,
      "type" => type,
      "payload" => payload
    }

    frame
    |> maybe_put("stream_seq", Keyword.get(opts, :stream_seq))
    |> maybe_put("occurred_at", Keyword.get(opts, :occurred_at))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ------------------------------------------------------------- helpers

  @doc "The API version for event frames (`lilium.chat.v1`)."
  def api_version, do: @api_version

  @doc "The API version for stream event frames (`lilium.chat.stream.v1`)."
  def stream_api_version, do: @stream_api_version

  @doc """
  Parse a raw command frame payload into `{command, command_id, channel_id, payload}`.

  Returns `{:ok, tuple}` or `{:error, reason}`.
  """
  def parse_command(%{"frame_type" => "command"} = frame) do
    command = Map.get(frame, "command")
    command_id = Map.get(frame, "command_id")
    channel_id = Map.get(frame, "channel_id")
    payload = Map.get(frame, "payload", %{})

    cond do
      is_nil(command) ->
        {:error, "missing command"}

      is_nil(command_id) or not is_binary(command_id) or command_id == "" ->
        {:error, "missing command_id"}

      true ->
        {:ok, {command, command_id, channel_id, payload}}
    end
  end

  def parse_command(_), do: {:error, "not a command frame"}
end
