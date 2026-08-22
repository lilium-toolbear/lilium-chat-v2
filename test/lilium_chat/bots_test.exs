defmodule LiliumChat.BotsTest do
  @moduledoc """
  Domain tests for the bot registry (issue #16, contract §9.10/§9.11).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.BotFixtures

  alias LiliumChat.Bots

  @owner "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  # --------------------------------------------------------------- cursors

  test "offset cursor round-trips; bad/missing cursors decode to 0" do
    for offset <- [0, 1, 19, 100, 10_000] do
      assert Bots.decode_offset_cursor(Bots.encode_offset_cursor(offset)) == offset
    end

    assert Bots.decode_offset_cursor(nil) == 0
    assert Bots.decode_offset_cursor("") == 0
    assert Bots.decode_offset_cursor("!!!") == 0
    assert Bots.decode_offset_cursor(Bots.encode_offset_cursor(5) <> "x") == 5
  end

  test "parse_limit clamps to 1..100 with a default for NaN" do
    assert Bots.parse_limit(nil, 20) == 20
    assert Bots.parse_limit("", 20) == 20
    assert Bots.parse_limit("abc", 20) == 20
    assert Bots.parse_limit("0", 20) == 1
    assert Bots.parse_limit("-3", 20) == 1
    assert Bots.parse_limit("50", 20) == 50
    assert Bots.parse_limit("999", 20) == 100
    assert Bots.parse_limit("30x", 20) == 30
  end

  # ----------------------------------------------------------------- create

  test "create: default initial token (lcbot_ plaintext, returned once)" do
    assert {:ok, %{bot: bot, initial_token: token}} =
             Bots.create(@owner, %{display_name: "My Bot"})

    assert bot["owner_user_id"] == @owner
    assert bot["display_name"] == "My Bot"
    assert bot["visibility"] == "private"
    assert bot["status"] == "active"
    assert bot["created_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/

    assert token.plaintext =~ ~r/^lcbot_[A-Za-z0-9_-]{43}$/
    assert token.scopes == ["chat:runtime:connect", "chat:commands:manage"]
    assert token.name == "default"

    # the plaintext verifies against the stored hash
    assert {:ok, %{bot_id: verified_bot_id}} = LiliumChat.BotTokens.verify(token.plaintext)
    assert verified_bot_id == bot["bot_id"]
  end

  test "create: issue_initial_token=false → nil initial_token" do
    assert {:ok, %{initial_token: nil}} =
             Bots.create(@owner, %{display_name: "No Token", issue_initial_token: false})
  end

  test "create: missing display_name → INVALID_MESSAGE" do
    assert {:error, err} = Bots.create(@owner, %{display_name: nil})
    assert err.code == "INVALID_MESSAGE"
  end

  # ------------------------------------------------------------------ list

  test "list_for_owner: excludes deleted, includes command_count, paginates" do
    b1 = seed_bot(@owner, display_name: "One")
    b2 = seed_bot(@owner, display_name: "Two")
    seed_bot(@owner, display_name: "Gone", status: "deleted")
    seed_bot(@other, display_name: "Foreign")

    seed_bot_command(b2, "alpha")
    seed_bot_command(b2, "beta")

    assert {:ok, %{items: items, next_cursor: nil}} = Bots.list_for_owner(@owner, %{})
    assert length(items) == 2

    two = Enum.find(items, &(&1["display_name"] == "Two"))
    assert two["command_count"] == 2
    refute two["command_count"] == nil

    one = Enum.find(items, &(&1["display_name"] == "One"))
    assert one["command_count"] == 0

    # pagination: limit=1 → next_cursor, then the second page
    assert {:ok, %{items: [first], next_cursor: cursor}} =
             Bots.list_for_owner(@owner, %{limit: "1"})

    assert is_binary(cursor)

    # Second page: still a full page (1 == limit) → next_cursor present
    assert {:ok, %{items: [second]}} =
             Bots.list_for_owner(@owner, %{limit: "1", cursor: cursor})

    assert first["bot_id"] != second["bot_id"]
    assert MapSet.new([first["bot_id"], second["bot_id"]]) == MapSet.new([b1, b2])
  end

  test "list_admin: filters q / owner_user_id / status / visibility" do
    _ = seed_bot(@owner, display_name: "Alpha One")
    _ = seed_bot(@owner, display_name: "Beta Two", visibility: "public")
    other_bot = seed_bot(@other, display_name: "Gamma Three", status: "disabled")

    assert {:ok, %{items: items}} = Bots.list_admin(%{q: "alpha"})
    assert [item] = items
    assert item["display_name"] == "Alpha One"

    assert {:ok, %{items: items}} = Bots.list_admin(%{owner_user_id: @other})
    assert [item] = items
    assert item["bot_id"] == other_bot

    assert {:ok, %{items: items}} = Bots.list_admin(%{status: "disabled"})
    assert [item] = items
    assert item["bot_id"] == other_bot

    assert {:ok, %{items: items}} = Bots.list_admin(%{visibility: "public"})
    assert [item] = items
    assert item["display_name"] == "Beta Two"
  end

  # ------------------------------------------------------------ get/update

  test "get: unknown → BOT_NOT_FOUND" do
    assert {:error, err} = Bots.get(Ecto.UUID.generate())
    assert err.code == "BOT_NOT_FOUND"
  end

  test "update: applies fields and bumps updated_at" do
    bot_id = seed_bot(@owner, display_name: "Old")

    assert {:ok, %{bot: updated}} =
             Bots.update(bot_id, [{"display_name", "New"}, {"status", "disabled"}])

    assert updated["display_name"] == "New"
    assert updated["status"] == "disabled"
  end

  test "update: no fields → INVALID_MESSAGE" do
    bot_id = seed_bot(@owner)
    assert {:error, err} = Bots.update(bot_id, [])
    assert err.code == "INVALID_MESSAGE"
  end

  test "update: invalid visibility / status rejected" do
    bot_id = seed_bot(@owner)
    assert {:error, err} = Bots.update(bot_id, [{"visibility", "shiny"}])
    assert err.code == "INVALID_MESSAGE"

    assert {:error, err} = Bots.update(bot_id, [{"status", "running"}])
    assert err.code == "INVALID_MESSAGE"
  end

  test "update: deleted bot → BOT_NOT_FOUND" do
    bot_id = seed_bot(@owner, status: "deleted")
    assert {:error, err} = Bots.update(bot_id, [{"display_name", "X"}])
    assert err.code == "BOT_NOT_FOUND"
  end

  # ---------------------------------------------------------------- tokens

  test "create_token: 201-shape with plaintext; list_tokens hides plaintext" do
    bot_id = seed_bot(@owner)

    assert {:ok, %{token: token}} = Bots.create_token(bot_id, %{name: "deploy"})
    assert token.plaintext =~ ~r/^lcbot_/
    assert token.name == "deploy"

    assert {:error, err} = Bots.create_token(bot_id, %{name: nil})
    assert err.code == "INVALID_MESSAGE"

    assert {:error, err} = Bots.create_token(Ecto.UUID.generate(), %{name: "x"})
    assert err.code == "BOT_NOT_FOUND"

    assert {:ok, %{items: items}} = Bots.list_tokens(bot_id)
    assert [listed] = items
    assert listed["token_id"] == token.token_id
    assert listed["name"] == "deploy"
    refute Map.has_key?(listed, "plaintext")
  end

  test "revoke_token: idempotent revoke; unknown token → BOT_TOKEN_INVALID" do
    bot_id = seed_bot(@owner)
    token_id = seed_bot_token(bot_id, LiliumChat.BotTokens.generate_plaintext())

    assert {:ok, %{token_id: ^token_id, revoked_at: ts}} =
             Bots.revoke_token(bot_id, token_id)

    assert ts =~ ~r/^\d{4}-\d{2}-\d{2}T/

    # second revoke returns the same revoked_at
    assert {:ok, %{revoked_at: ts2}} = Bots.revoke_token(bot_id, token_id)
    assert ts2 == ts

    assert {:error, err} = Bots.revoke_token(bot_id, Ecto.UUID.generate())
    assert err.code == "BOT_TOKEN_INVALID"
  end
end
