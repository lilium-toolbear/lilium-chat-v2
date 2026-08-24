defmodule LiliumChat.BotStreamTest do
  @moduledoc """
  Bot Stream WS frame codec (contract §9.15.2, issue #18).
  """

  use ExUnit.Case, async: true

  alias LiliumChat.BotStream

  @api "lilium.chat.bot.stream.v1"

  test "api_version constant" do
    assert BotStream.api_version() == @api
  end

  test "hello / ready / ping / pong" do
    assert {:ok, %{}} = BotStream.parse_hello(%{"type" => "hello", "api_version" => @api})

    ready =
      BotStream.build_ready(%{
        channel_id: "ch",
        message_id: "mid",
        expires_at: "2026-01-01T00:00:00Z",
        ack_seq: 0
      })

    assert ready["type"] == "ready"
    assert ready["api_version"] == @api
    assert ready["channel_id"] == "ch"
    assert ready["message_id"] == "mid"
    assert ready["ack_seq"] == 0

    assert {:ok, %{}} = BotStream.parse_ping(%{"type" => "ping", "api_version" => @api})
    assert BotStream.build_pong()["type"] == "pong"
  end

  test "parse_append requires seq + delta" do
    assert {:ok, %{seq: 1, delta: "hi"}} =
             BotStream.parse_append(%{
               "type" => "append",
               "api_version" => @api,
               "seq" => 1,
               "delta" => "hi"
             })

    assert {:error, _} =
             BotStream.parse_append(%{"type" => "append", "api_version" => @api, "seq" => 1})
  end

  test "parse_finalize accepts optional components / attachment_ids" do
    assert {:ok, %{final_seq: 3, components: nil, attachment_ids: nil}} =
             BotStream.parse_finalize(%{
               "type" => "finalize",
               "api_version" => @api,
               "final_seq" => 3
             })

    assert {:ok, %{final_seq: 3, components: [%{"t" => 1}], attachment_ids: ["a"]}} =
             BotStream.parse_finalize(%{
               "type" => "finalize",
               "api_version" => @api,
               "final_seq" => 3,
               "components" => [%{"t" => 1}],
               "attachment_ids" => ["a"]
             })
  end

  test "append_ack / finalized_ack / stream_error builders" do
    ack = BotStream.build_append_ack(4)
    assert ack["type"] == "append_ack"
    assert ack["ack_seq"] == 4

    done = BotStream.build_finalized_ack("mid", "eid")
    assert done["type"] == "finalized_ack"
    assert done["ok"] == true
    assert done["message_id"] == "mid"
    assert done["event_id"] == "eid"

    err = BotStream.build_error("BOT_STREAM_SEQUENCE_GAP", "append sequence gap")
    assert err["type"] == "stream_error"
    assert err["code"] == "BOT_STREAM_SEQUENCE_GAP"
    assert err["retryable"] == true
    assert err["message"] == "append sequence gap"
  end

  test "hello rejects wrong api_version" do
    assert {:error, _} = BotStream.parse_hello(%{"type" => "hello", "api_version" => "nope"})
  end
end
