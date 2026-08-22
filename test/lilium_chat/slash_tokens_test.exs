defmodule LiliumChat.SlashTokensTest do
  @moduledoc """
  Unit tests for slash-token normalization (issue #16, old `slash-token.ts`).
  """

  use ExUnit.Case

  alias LiliumChat.SlashTokens

  describe "normalize/1" do
    test "trims, strips leading slashes, lowercases" do
      assert SlashTokens.normalize("  /Hello ") == "hello"
      assert SlashTokens.normalize("//HELLO") == "hello"
      assert SlashTokens.normalize("/Hello") == "hello"
    end

    test "NFKC normalizes fullwidth and compatible characters" do
      # fullwidth "Ｈｅｌｌｏ"
      assert SlashTokens.normalize("Ｈｅｌｌｏ") == "hello"
      # "ﬁ" ligature (U+FB01) normalizes to "fi" under NFKC
      assert SlashTokens.normalize("ﬁle") == "file"
    end

    test "keeps interior slashes" do
      assert SlashTokens.normalize("a/b") == "a/b"
    end
  end

  describe "validate/1" do
    test "empty token" do
      assert SlashTokens.validate("") == {:error, "empty"}
      assert SlashTokens.validate("///") == {:error, "empty"}
    end

    test "too long (33+ chars)" do
      assert SlashTokens.validate(String.duplicate("a", 33)) == {:error, "too_long"}
      assert SlashTokens.validate(String.duplicate("a", 32)) == {:ok, String.duplicate("a", 32)}
    end

    test "invalid characters: whitespace, interior slash, control" do
      assert SlashTokens.validate("a b") == {:error, "invalid_characters"}
      assert SlashTokens.validate("a/b") == {:error, "invalid_characters"}
      assert SlashTokens.validate("a\tb") == {:error, "invalid_characters"}
    end

    test "valid token" do
      # interior whitespace survives normalization → invalid
      assert SlashTokens.validate("ok token") == {:error, "invalid_characters"}
      assert SlashTokens.validate("ok-token_1") == {:ok, "ok-token_1"}
    end
  end

  describe "collect/2" do
    test "returns canonical + aliases + all" do
      assert {:ok, %{canonical: "hi", aliases: ["hey"], all: ["hi", "hey"]}} =
               SlashTokens.collect("Hi", ["Hey"])
    end

    test "case-insensitive duplicate alias vs canonical fails" do
      assert {:error, "duplicate_in_request"} = SlashTokens.collect("Hi", ["hi"])
    end

    test "duplicate alias fails" do
      assert {:error, "duplicate_in_request"} = SlashTokens.collect("Hi", ["hey", "HEY"])
    end

    test "invalid canonical propagates" do
      assert {:error, "empty"} = SlashTokens.collect("", ["x"])
    end
  end
end
