defmodule LiliumChat.CanonicalJSONTest do
  @moduledoc """
  Unit tests for canonical JSON encoding + hashing (issue #16).
  """

  use ExUnit.Case

  alias LiliumChat.CanonicalJSON

  describe "encode/1" do
    test "objects keep insertion order (unlike Jason's sorted keys)" do
      assert CanonicalJSON.encode([{"b", 1}, {"a", 2}]) == ~s({"b":1,"a":2})
    end

    test "arrays and empty values" do
      assert CanonicalJSON.encode(["x", ["y"]]) == ~s(["x",["y"]])
      assert CanonicalJSON.encode([]) == "[]"
      assert CanonicalJSON.encode(nil) == "null"
      assert CanonicalJSON.encode(true) == "true"
      assert CanonicalJSON.encode(false) == "false"
      assert CanonicalJSON.encode(42) == "42"
    end

    test "nested objects and arrays" do
      # an object whose value is another object
      assert CanonicalJSON.encode([{"outer", [{"inner", ["a", 1]}]}]) ==
               ~s({"outer":{"inner":["a",1]}})

      # an object whose value is an array of primitives
      assert CanonicalJSON.encode([{"list", ["a", 1]}]) == ~s({"list":["a",1]})
    end

    test "string escaping matches JSON.stringify" do
      assert CanonicalJSON.encode("a\"b\\c") == ~s("a\\\"b\\\\c")
      assert CanonicalJSON.encode("tab\tnewline\n") == ~s("tab\\tnewline\\n")
      # control char 0x01 → \u0001 (six literal chars: backslash-u-0-0-0-1)
      assert CanonicalJSON.encode("a" <> <<0x01>> <> "b") == "\"a\\u0001b\""
      # non-ASCII passes through verbatim
      assert CanonicalJSON.encode("命令") == "\"命令\""
    end

    test "floats: integral floats drop the fraction" do
      assert CanonicalJSON.encode(1.0) == "1"
      assert CanonicalJSON.encode(1.5) == "1.5"
      assert CanonicalJSON.encode(0.1) == "0.1"
    end
  end

  describe "encode_and_sha256/1" do
    test "hashes the canonical byte form" do
      assert CanonicalJSON.encode_and_sha256([{"commands", []}]) ==
               :crypto.hash(:sha256, ~s({"commands":[]})) |> Base.encode16(case: :lower)
    end

    test "is deterministic and case-sensitive in key order" do
      a = [{"a", 1}, {"b", 2}]
      b = [{"b", 2}, {"a", 1}]
      assert CanonicalJSON.encode_and_sha256(a) == CanonicalJSON.encode_and_sha256(a)
      assert CanonicalJSON.encode_and_sha256(a) != CanonicalJSON.encode_and_sha256(b)
    end
  end
end
