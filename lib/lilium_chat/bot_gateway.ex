defmodule LiliumChat.BotGateway do
  @moduledoc """
  Bot Gateway WS frame codec (contract §9.7, issue #17).

  Pure builders/parsers for the `lilium.chat.bot.v1` WebSocket frames,
  mirroring the old Worker's `src/chat/bot-gateway-protocol.ts`:

    * hello / ready handshake
    * `delivery` frames (kinds: `command_invocation`, `message_interaction`,
      `message_event`)
    * `delivery_result` (bot → server) and `delivery_ack` (server → bot)
    * ping / pong keepalive

  Wire shapes are authoritative from `docs/api-contract.md` §9.7 — when this
  module and the old Worker differ, this module (and the contract) win.
  """

  @api_version "lilium.chat.bot.v1"

  # delivery_result limits (contract §9.7 / old Worker parseDeliveryResult)
  @max_delivery_effects 20
  @max_effect_length 1000

  # Effect types accepted by the main gateway (contract §9.7 / §9.14).
  # `append_stream` / `finalize_stream` belong to the stateful (stream)
  # gateway and are rejected on this socket (BOT_EFFECT_INVALID).
  @main_gateway_effect_types [
    "send_message",
    "update_message",
    "disable_components",
    "start_stream",
    "set_channel_pin",
    "update_channel_pin",
    "clear_channel_pin"
  ]

  @rejected_effect_types ["append_stream", "finalize_stream"]

  # ------------------------------------------------------------------ consts

  @doc "The Bot Gateway API version (WS subprotocol)."
  def api_version(), do: @api_version

  @doc "Delivery kinds carried on the Bot Gateway (contract §9.7)."
  def delivery_kinds(), do: ["command_invocation", "message_interaction", "message_event"]

  @doc """
  Effect types accepted by the main gateway (contract §9.7 / §9.14).
  Single source of truth: `LiliumChat.BotEffects.validate/2` gates on this
  list, and `apply_one/3` dispatch must cover it.
  """
  def main_gateway_effect_types(), do: @main_gateway_effect_types

  @doc "Effect types rejected on the main gateway (stateful-gateway only)."
  def rejected_effect_types(), do: @rejected_effect_types

  # ------------------------------------------------------------------- hello

  @doc """
  Parse and validate a `hello` frame (bot → server).

  Returns `{:ok, last_received_delivery_id}` (nil or binary) or
  `{:error, reason}`. Malformed frames are swallowed by the channel (old
  Worker parity: log + keep the socket open for a retry hello).
  """
  def parse_hello(%{} = frame) do
    with :ok <- check_type(frame, "hello"),
         :ok <- check_api_version(frame) do
      case frame["last_received_delivery_id"] do
        nil -> {:ok, nil}
        value when is_binary(value) -> {:ok, value}
        _ -> {:error, "last_received_delivery_id must be null or a string"}
      end
    end
  end

  def parse_hello(_), do: {:error, "not a hello frame"}

  # ------------------------------------------------------------------- ready

  @doc "Build the `ready` frame (server → bot, hello reply; contract §9.7.1)."
  def build_ready(bot_id, session_id) do
    %{
      "type" => "ready",
      "api_version" => @api_version,
      "bot_id" => bot_id,
      "session_id" => session_id,
      "server_time" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  # ---------------------------------------------------------------- delivery

  @doc """
  Build a `delivery` frame from a `bot_deliveries` row (string-keyed map with
  `delivery_id`, `kind`, `channel_id`, `request_json`).

  `request_json` carries the resolved delivery body (contract §9.7.1); the
  envelope fields (`type`, `api_version`, `delivery_id`, `kind`, `channel_id`)
  are added here.
  """
  def build_delivery_frame(%{
        "delivery_id" => delivery_id,
        "kind" => kind,
        "channel_id" => channel_id,
        "request_json" => body
      })
      when is_map(body) do
    base = %{
      "type" => "delivery",
      "api_version" => @api_version,
      "delivery_id" => delivery_id,
      "kind" => kind,
      "channel_id" => channel_id
    }

    Map.merge(base, body)
  end

  # -------------------------------------------------------- delivery_result

  @doc """
  Parse and validate a `delivery_result` frame (bot → server).

  Returns `{:ok, %{delivery_id, status, effects}}` or `{:error, reason}`.
  Per-effect validation (type, fields, idempotency) happens in
  `LiliumChat.BotEffects`.
  """
  def parse_delivery_result(%{} = frame) do
    with :ok <- check_type(frame, "delivery_result"),
         :ok <- check_api_version(frame),
         delivery_id <- frame["delivery_id"],
         :ok <- check_binary_id(delivery_id),
         :ok <- check_result_status(frame["status"]),
         effects when is_list(effects) <- frame["effects"],
         :ok <- check_effects_count(effects),
         :ok <- validate_effects_lengths(effects) do
      {:ok, %{delivery_id: delivery_id, status: "ok", effects: effects}}
    end
  end

  def parse_delivery_result(_), do: {:error, "not a delivery_result frame"}

  # ----------------------------------------------------------- delivery_ack

  @doc """
  Build a `delivery_ack` frame (server → bot).

  `status` is `"applied"` (with `effect_results`) or `"failed"` (with
  `error: {code, message}` — no `retryable`, per the contract ack shape).
  """
  def build_delivery_ack(delivery_id, "applied", %{"effect_results" => results})
      when is_list(results) do
    %{
      "type" => "delivery_ack",
      "api_version" => @api_version,
      "delivery_id" => delivery_id,
      "status" => "applied",
      "effect_results" => results
    }
  end

  def build_delivery_ack(delivery_id, "failed", %{"error" => error}) when is_map(error) do
    %{
      "type" => "delivery_ack",
      "api_version" => @api_version,
      "delivery_id" => delivery_id,
      "status" => "failed",
      "error" => %{
        "code" => error["code"] || "BOT_EFFECT_INVALID",
        "message" => error["message"] || "effect failed"
      }
    }
  end

  # -------------------------------------------------------------------- pong

  @doc "Build a `pong` frame (server → bot, ping reply)."
  def build_pong() do
    %{"type" => "pong", "api_version" => @api_version}
  end

  # -------------------------------------------------------------- internals

  defp check_type(frame, expected) do
    if frame["type"] == expected do
      :ok
    else
      {:error, "unexpected frame type: #{inspect(frame["type"])}"}
    end
  end

  defp check_api_version(frame) do
    if frame["api_version"] == @api_version do
      :ok
    else
      {:error, "unsupported api_version: #{inspect(frame["api_version"])}"}
    end
  end

  defp check_effects_count(effects) do
    if length(effects) <= @max_delivery_effects do
      :ok
    else
      {:error, "too many effects (max #{@max_delivery_effects})"}
    end
  end

  defp check_result_status("ok"), do: :ok

  defp check_result_status(status), do: {:error, "status must be \"ok\": #{inspect(status)}"}

  defp check_binary_id(value),
    do: if(is_binary(value), do: :ok, else: {:error, "delivery_id must be a string"})

  # Each effect must be a small JSON object (old Worker: reject >1000 chars,
  # which also bounds the `client_effect_id` + body size per effect).
  defp validate_effects_lengths(effects) do
    if Enum.all?(effects, fn effect ->
         is_map(effect) and
           is_binary(effect["client_effect_id"]) and
           byte_size(Jason.encode!(effect)) <= @max_effect_length
       end) do
      :ok
    else
      {:error,
       "each effect must be an object with a client_effect_id (≤#{@max_effect_length} chars)"}
    end
  end
end
