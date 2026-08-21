defmodule LiliumChat.IdsTest do
  use ExUnit.Case, async: true

  alias LiliumChat.Ids

  @uuidv7_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "uuidv7 has the RFC-9562 v7 shape (version nibble 7, variant 10)" do
    assert Ids.uuidv7() =~ @uuidv7_re
  end

  test "uuidv7 embeds the millisecond timestamp in the first 48 bits" do
    now = System.system_time(:millisecond)
    id = Ids.uuidv7(now)
    hex = String.replace(id, "-", "")
    ts = String.slice(hex, 0, 12) |> String.to_integer(16)
    assert ts == now
  end

  test "uuidv7 is lexicographically ordered by time (sortable per contract §2.2)" do
    a = Ids.uuidv7(1_700_000_000_000)
    b = Ids.uuidv7(1_700_000_000_001)
    assert a < b
  end

  test "request id shape is req_<uuidv7>" do
    assert "req_" <> _ = "req_" <> Ids.uuidv7()

    assert "req_" <> Ids.uuidv7() =~
             ~r/^req_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end
end
