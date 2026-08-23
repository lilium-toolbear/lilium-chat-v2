defmodule LiliumChat.BotTokensTest do
  @moduledoc """
  Unit + DB tests for bot token hashing/verification (issue #16).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.BotFixtures

  alias LiliumChat.BotTokens

  test "hash is lowercase hex sha256" do
    assert BotTokens.hash("lcbot_x") ==
             :crypto.hash(:sha256, "lcbot_x") |> Base.encode16(case: :lower)
  end

  test "generate_plaintext is lcbot_ + 32 random bytes base64url (no padding)" do
    token = BotTokens.generate_plaintext()
    # base64url may itself contain `_`, so slice off the fixed prefix rather
    # than splitting on `_`.
    assert String.starts_with?(token, "lcbot_")
    rest = String.slice(token, 6..-1//1)
    # base64url(32 bytes) without padding
    assert String.length(rest) == 43
  end

  test "default scopes" do
    assert BotTokens.default_scopes() == ["chat:runtime:connect", "chat:commands:manage"]
  end

  test "scopes round-trip through the stored JSON string" do
    stored = BotTokens.scopes_json(["a:b", "c:d"])
    assert stored == ~s(["a:b","c:d"])
    assert BotTokens.scopes_from_stored(stored) == ["a:b", "c:d"]
    assert BotTokens.scopes_from_stored("garbage") == []
    assert BotTokens.scopes_from_stored(nil) == []
  end

  test "verify: valid token resolves bot + scopes" do
    bot_id = seed_bot("owner-1")
    plaintext = BotTokens.generate_plaintext()
    seed_bot_token(bot_id, plaintext, scopes: ["chat:commands:manage"])

    assert {:ok, %{bot_id: ^bot_id, scopes: ["chat:commands:manage"]}} =
             BotTokens.verify(plaintext)
  end

  test "verify: unknown token → UNAUTHORIZED Invalid bot token" do
    bot_id = seed_bot("owner-1")
    seed_bot_token(bot_id, BotTokens.generate_plaintext())

    assert {:error, err} = BotTokens.verify("lcbot_unknown")
    assert err.code == "UNAUTHORIZED"
    assert err.message == "Invalid bot token"
  end

  test "verify: revoked token fails" do
    bot_id = seed_bot("owner-1")
    plaintext = BotTokens.generate_plaintext()
    seed_bot_token(bot_id, plaintext, revoked_at: DateTime.utc_now())

    assert {:error, %LiliumChat.Errors.ApiError{code: "UNAUTHORIZED"}} =
             BotTokens.verify(plaintext)
  end

  test "verify: expired token fails" do
    bot_id = seed_bot("owner-1")
    plaintext = BotTokens.generate_plaintext()
    seed_bot_token(bot_id, plaintext, expires_at: DateTime.utc_now())

    assert {:error, %LiliumChat.Errors.ApiError{code: "UNAUTHORIZED"}} =
             BotTokens.verify(plaintext)
  end

  test "verify: inactive bot's token fails" do
    bot_id = seed_bot("owner-1", status: "disabled")
    plaintext = BotTokens.generate_plaintext()
    seed_bot_token(bot_id, plaintext)

    assert {:error, %LiliumChat.Errors.ApiError{code: "UNAUTHORIZED"}} =
             BotTokens.verify(plaintext)
  end

  test "verify: future expires_at is still valid (issue #17 expiry comparison fix)" do
    bot_id = seed_bot("owner-1")
    plaintext = BotTokens.generate_plaintext()

    seed_bot_token(
      bot_id,
      plaintext,
      expires_at: DateTime.utc_now() |> DateTime.add(3_600, :second)
    )

    assert {:ok, %{bot_id: ^bot_id, scopes: _}} = BotTokens.verify(plaintext)
  end

  test "verify: expired token with future-looking naive comparison still fails" do
    bot_id = seed_bot("owner-1")
    plaintext = BotTokens.generate_plaintext()

    seed_bot_token(
      bot_id,
      plaintext,
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)
    )

    assert {:error, %LiliumChat.Errors.ApiError{code: "UNAUTHORIZED"}} =
             BotTokens.verify(plaintext)
  end
end
