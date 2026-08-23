defmodule LiliumChat.BotGatewayTest do
  @moduledoc """
  Bot Gateway frame codec tests (contract §9.7, issue #17).
  Mirrors the old Worker's bot-gateway-protocol.ts behaviour.
  """

  use ExUnit.Case, async: true

  alias LiliumChat.BotGateway

  @api_version "lilium.chat.bot.v1"

  # ------------------------------------------------------------------- hello

  test "parse_hello accepts a bare hello" do
    assert {:ok, nil} =
             BotGateway.parse_hello(%{"type" => "hello", "api_version" => @api_version})
  end

  test "parse_hello carries last_received_delivery_id" do
    assert {:ok, "abc-123"} =
             BotGateway.parse_hello(%{
               "type" => "hello",
               "api_version" => @api_version,
               "last_received_delivery_id" => "abc-123"
             })
  end

  test "parse_hello rejects wrong type / api_version / bad last_received" do
    assert {:error, _} =
             BotGateway.parse_hello(%{"type" => "pong", "api_version" => @api_version})

    assert {:error, _} =
             BotGateway.parse_hello(%{"type" => "hello", "api_version" => "lilium.chat.bot.v2"})

    assert {:error, _} =
             BotGateway.parse_hello(%{
               "type" => "hello",
               "api_version" => @api_version,
               "last_received_delivery_id" => 42
             })

    assert {:error, _} = BotGateway.parse_hello([1, 2])
  end

  # ------------------------------------------------------------------- ready

  test "build_ready shape" do
    assert %{
             "type" => "ready",
             "api_version" => @api_version,
             "bot_id" => "bot-1",
             "session_id" => "sess-1",
             "server_time" => server_time
           } = BotGateway.build_ready("bot-1", "sess-1")

    # ISO-8601 UTC timestamp (contract §9.7.1 ready example).
    assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(server_time)
  end

  # -------------------------------------------------------------- delivery

  test "build_delivery_frame adds the envelope around the stored body" do
    body = %{
      "invocation_id" => "inv-1",
      "command" => %{"bot_command_id" => "bc-1", "name" => "ask"},
      "invoker" => %{"user_id" => "u-1", "display_name" => "Kuma", "avatar_url" => nil}
    }

    frame =
      BotGateway.build_delivery_frame(%{
        "delivery_id" => "d-1",
        "kind" => "command_invocation",
        "channel_id" => "ch-1",
        "request_json" => body
      })

    assert frame["type"] == "delivery"
    assert frame["api_version"] == @api_version
    assert frame["delivery_id"] == "d-1"
    assert frame["kind"] == "command_invocation"
    assert frame["channel_id"] == "ch-1"
    assert frame["invocation_id"] == "inv-1"
    assert frame["command"] == %{"bot_command_id" => "bc-1", "name" => "ask"}
    assert frame["invoker"]["user_id"] == "u-1"
  end

  # -------------------------------------------------------- delivery_result

  test "parse_delivery_result accepts a valid frame" do
    effects = [
      %{"type" => "send_message", "client_effect_id" => "ce-1", "message" => %{"text" => "hi"}}
    ]

    assert {:ok, %{delivery_id: "d-1", status: "ok", effects: ^effects}} =
             BotGateway.parse_delivery_result(%{
               "type" => "delivery_result",
               "api_version" => @api_version,
               "delivery_id" => "d-1",
               "status" => "ok",
               "effects" => effects
             })
  end

  test "parse_delivery_result enforces the 20-effect and per-effect limits" do
    frame = fn effects ->
      %{
        "type" => "delivery_result",
        "api_version" => @api_version,
        "delivery_id" => "d-1",
        "status" => "ok",
        "effects" => effects
      }
    end

    ok_effects =
      for n <- 1..20 do
        %{"type" => "send_message", "client_effect_id" => "ce-#{n}"}
      end

    assert {:ok, _} = BotGateway.parse_delivery_result(frame.(ok_effects))

    assert {:error, _} =
             BotGateway.parse_delivery_result(
               frame.(ok_effects ++ [%{"client_effect_id" => "ce-21"}])
             )

    assert {:error, _} =
             BotGateway.parse_delivery_result(
               frame.([%{"client_effect_id" => String.duplicate("x", 1001)}])
             )

    assert {:error, _} = BotGateway.parse_delivery_result(frame.(["not-a-map"]))

    # codec level: each effect must carry a client_effect_id
    assert {:error, _} = BotGateway.parse_delivery_result(frame.([%{"type" => "send_message"}]))

    assert {:error, _} =
             BotGateway.parse_delivery_result(%{
               "type" => "delivery_result",
               "api_version" => @api_version,
               "delivery_id" => "d-1",
               "status" => "weird",
               "effects" => []
             })
  end

  # ----------------------------------------------------------- delivery_ack

  test "build_delivery_ack applied / failed shapes" do
    applied =
      BotGateway.build_delivery_ack("d-1", "applied", %{
        "effect_results" => [
          %{
            "client_effect_id" => "ce-1",
            "type" => "send_message",
            "status" => "applied",
            "message_id" => "m-1"
          }
        ]
      })

    assert applied["type"] == "delivery_ack"
    assert applied["api_version"] == @api_version
    assert applied["delivery_id"] == "d-1"
    assert applied["status"] == "applied"

    assert applied["effect_results"] == [
             %{
               "client_effect_id" => "ce-1",
               "type" => "send_message",
               "status" => "applied",
               "message_id" => "m-1"
             }
           ]

    failed =
      BotGateway.build_delivery_ack("d-1", "failed", %{
        "error" => %{"code" => "BOT_EFFECT_CONFLICT", "message" => "conflict"}
      })

    assert failed["status"] == "failed"
    assert failed["error"] == %{"code" => "BOT_EFFECT_CONFLICT", "message" => "conflict"}
  end

  # -------------------------------------------------------------------- misc

  test "build_pong shape" do
    assert %{"type" => "pong", "api_version" => @api_version} = BotGateway.build_pong()
  end

  test "effect type lists" do
    assert BotGateway.main_gateway_effect_types() == [
             "send_message",
             "update_message",
             "disable_components",
             "start_stream",
             "set_channel_pin",
             "update_channel_pin",
             "clear_channel_pin"
           ]

    assert BotGateway.rejected_effect_types() == ["append_stream", "finalize_stream"]

    assert BotGateway.delivery_kinds() == [
             "command_invocation",
             "message_interaction",
             "message_event"
           ]
  end
end
