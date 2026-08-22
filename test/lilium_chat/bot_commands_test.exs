defmodule LiliumChat.BotCommandsTest do
  @moduledoc """
  Domain tests for the bot command catalog (issue #16, contract §9.3).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.BotFixtures

  alias LiliumChat.{BotCommands, Repo}

  @bot "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee01"
  @bot2 "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee02"
  @owner "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  setup do
    seed_bot(@owner, bot_id: @bot, display_name: "Bot A")
    seed_bot(@owner, bot_id: @bot2, display_name: "Bot B")
    :ok
  end

  defp command(name, opts \\ []) do
    %{
      "name" => name,
      "aliases" => Keyword.get(opts, :aliases, []),
      "description" => Keyword.get(opts, :description, "#{name} description"),
      "help_text" => Keyword.get(opts, :help_text, ""),
      "options" => Keyword.get(opts, :options, []),
      "default_member_permission" => Keyword.get(opts, :permission, "member"),
      "execution" => Keyword.get(opts, :execution, %{"mode" => "stateless"})
    }
  end

  # ------------------------------------------------------------------ sync

  test "sync: new command → 200-shape items + DB rows" do
    assert {:ok, %{"commands" => items}} =
             BotCommands.sync(@bot, "key-1", [command("roll", aliases: ["dice"])])

    assert [
             %{
               "bot_command_id" => id,
               "name" => "roll",
               "aliases" => ["dice"],
               "status" => "active",
               "execution_mode" => "stateless",
               "definition_hash" => hash,
               "schema_version" => 1
             }
           ] = items

    assert hash =~ ~r/^[0-9a-f]{64}$/
    assert is_binary(id)

    # slash-token namespace rows
    names =
      Repo.query(
        "SELECT slash_token, kind FROM chat_v2.bot_command_names WHERE bot_command_id = $1 ORDER BY slash_token",
        [id]
      )
      |> LiliumChat.Query.rows()

    assert %{"slash_token" => "dice", "kind" => "alias"} = List.first(names)
    assert %{"slash_token" => "roll", "kind" => "canonical"} = Enum.at(names, 1)
  end

  test "sync: unchanged re-sync keeps schema_version; changed definition bumps it" do
    assert {:ok, %{"commands" => [%{"bot_command_id" => id, "schema_version" => 1}]}} =
             BotCommands.sync(@bot, "key-1", [command("roll")])

    assert {:ok, %{"commands" => [%{"schema_version" => 1}]}} =
             BotCommands.sync(@bot, "key-2", [command("roll")])

    assert {:ok, %{"commands" => [%{"bot_command_id" => id2, "schema_version" => 2}]}} =
             BotCommands.sync(@bot, "key-3", [command("roll", description: "new")])

    assert id2 == id
  end

  test "sync: full alias replacement on re-sync" do
    assert {:ok, %{"commands" => [%{"bot_command_id" => id}]}} =
             BotCommands.sync(@bot, "key-1", [command("roll", aliases: ["dice"])])

    assert {:ok, _} = BotCommands.sync(@bot, "key-2", [command("roll", aliases: ["d20"])])

    aliases =
      Repo.query(
        "SELECT alias FROM chat_v2.bot_command_aliases WHERE bot_command_id = $1 ORDER BY alias",
        [id]
      )
      |> LiliumChat.Query.rows()
      |> Enum.map(& &1["alias"])

    assert aliases == ["d20"]
  end

  test "sync: idempotent replay returns the stored response" do
    assert {:ok, response} = BotCommands.sync(@bot, "key-1", [command("roll")])
    assert {:ok, replayed} = BotCommands.sync(@bot, "key-1", [command("roll")])
    assert replayed == response
  end

  test "sync: same key, different body → IDEMPOTENCY_CONFLICT" do
    assert {:ok, _} = BotCommands.sync(@bot, "key-1", [command("roll")])

    assert {:error, err} =
             BotCommands.sync(@bot, "key-1", [command("roll", description: "different")])

    assert err.code == "IDEMPOTENCY_CONFLICT"
  end

  test "sync: duplicate slash token inside the request fails the whole sync" do
    commands = [
      command("roll", aliases: ["dice"]),
      command("dice", description: "other")
    ]

    assert {:error, err} = BotCommands.sync(@bot, "key-1", commands)
    assert err.code == "INVALID_COMMAND_OPTIONS"
    assert err.message == "duplicate slash token: dice"
  end

  test "sync: token owned by another command → COMMAND_NAME_CONFLICT with detail" do
    other_id = seed_bot_command(@bot2, "roll")

    assert {:conflict, err, conflict} =
             BotCommands.sync(@bot, "key-1", [command("roll")])

    assert err.code == "COMMAND_NAME_CONFLICT"
    assert conflict == %{slash_token: "roll", bot_command_id: other_id, bot_id: @bot2}
  end

  test "sync: same bot reusing its own token is not a conflict" do
    assert {:ok, %{"commands" => [%{"bot_command_id" => id}]}} =
             BotCommands.sync(@bot, "key-1", [command("roll")])

    # re-sync the same command under the same bot: same id, no conflict
    assert {:ok, %{"commands" => [%{"bot_command_id" => id2}]}} =
             BotCommands.sync(@bot, "key-2", [command("roll")])

    assert id2 == id
  end

  # ------------------------------------------------------------ get_current

  test "get_current: active command returns the full snapshot" do
    id = seed_bot_command(@bot, "roll", aliases: ["dice"])

    assert {:ok, snapshot} = BotCommands.get_current(id)
    assert snapshot["bot_command_id"] == id
    assert snapshot["name"] == "roll"
    assert snapshot["aliases"] == ["dice"]
    assert snapshot["bot"]["bot_id"] == @bot
    # The snapshot execution is the clean wire shape `{mode, stateful?}` —
    # schema_version / definition_hash are catalog columns, not wire fields.
    assert snapshot["execution"] == %{"mode" => "stateless"}
  end

  test "get_current: disabled / deleted → BOT_COMMAND_DISABLED" do
    id = seed_bot_command(@bot, "roll", status: "disabled")
    assert {:error, err} = BotCommands.get_current(id)
    assert err.code == "BOT_COMMAND_DISABLED"

    id2 = seed_bot_command(@bot, "gone", status: "active")

    Repo.query!(
      "UPDATE chat_v2.bot_commands SET deleted_at = $1 WHERE bot_command_id = $2",
      [DateTime.utc_now(), id2],
      type: true
    )

    assert {:error, err} = BotCommands.get_current(id2)
    assert err.code == "BOT_COMMAND_DISABLED"
  end

  # ------------------------------------------------------------- directory

  test "directory: searches by name and alias; execution has no schema_version" do
    id = seed_bot_command(@bot, "roll", aliases: ["dice"], description: "roll a dice")
    seed_bot_command(@bot, "other", description: "something else")
    seed_bot_command(@bot, "hidden", status: "disabled")

    assert {:ok, %{items: items, next_cursor: nil}} =
             BotCommands.directory("roll", nil, nil)

    assert [found] = items
    assert found["bot_command_id"] == id
    assert found["aliases"] == ["dice"]
    assert found["execution"] == %{"mode" => "stateless"}
    refute Map.has_key?(found, "schema_version")
    refute Map.has_key?(found, "definition_hash")
    assert found["bot"]["display_name"] == "Bot A"

    # alias match
    assert {:ok, %{items: [alias_hit]}} = BotCommands.directory("dice", nil, nil)
    assert alias_hit["bot_command_id"] == id
  end

  test "directory: limit + cursor pagination" do
    for i <- 1..3, do: seed_bot_command(@bot, "cmd-#{i}")

    assert {:ok, %{items: [first], next_cursor: cursor}} =
             BotCommands.directory(nil, "1", nil)

    assert is_binary(cursor)

    assert {:ok, %{items: rest}} = BotCommands.directory(nil, "1", cursor)
    assert length(rest) == 1
    assert hd(rest)["bot_command_id"] != first["bot_command_id"]
  end
end
