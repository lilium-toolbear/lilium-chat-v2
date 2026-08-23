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

  # ------------------------------------------------ monotonic event_id (issue #10)

  test "monotonic counter round-trips for all 4096 values through encode + parse_monotonic" do
    base_ms = 0x1A0F_0000_0000

    Enum.each(0..0xFFF, fn counter ->
      # the next id allocated FROM this seq carries counter+1 (rolling into
      # the next ms slot at the 12-bit cap)
      {id, _next} = Ids.monotonic_uuidv7(%{last_ms: base_ms, counter: counter}, base_ms)

      expected_ms = if counter == 0xFFF, do: base_ms + 1, else: base_ms
      expected_counter = if counter == 0xFFF, do: 0, else: counter + 1

      recovered = Ids.parse_monotonic(id)

      assert recovered == %{last_ms: expected_ms, counter: expected_counter},
             "counter #{counter} (0x#{Integer.to_string(counter, 16)}) did not round-trip via #{id}"
    end)
  end

  test "boundary counters (low byte < 0x10) encode as fixed 3-digit fields" do
    # 0x8FF -> next counter 0x900: the historical corruption case ("90" was
    # left-padded to "090" and parsed back as 0x090).
    {id, seq} = Ids.monotonic_uuidv7(%{last_ms: 0x1A0F, counter: 0x8FF}, 0x1A0F)
    assert seq.counter == 0x900
    assert id =~ "900"

    {id2, seq2} = Ids.monotonic_uuidv7(seq, 0x1A0F)
    assert seq2.counter == 0x901
    assert id2 =~ "901"
    assert id < id2
  end

  test "same-ms allocation chain is strictly increasing; the 12-bit cap wraps at 0xFFF" do
    # in-millisecond chain (old Worker parity: 12-bit counter, 4096/ms cap)
    seq = %{last_ms: 0x1A0F, counter: 0x100}

    {id1, seq1} = Ids.monotonic_uuidv7(seq, 0x1A0F)
    {id2, seq2} = Ids.monotonic_uuidv7(seq1, 0x1A0F)
    {id3, _seq3} = Ids.monotonic_uuidv7(seq2, 0x1A0F)

    assert [seq1.counter, seq2.counter] == [0x101, 0x102]
    assert id1 < id2
    assert id2 < id3

    # exhaustion: from 0xFFD the chain runs 0xFFE, 0xFFF, then rolls into
    # the NEXT ms slot (strictly increasing — no 12-bit wrap-back)
    wrap = %{last_ms: 0x1A0F, counter: 0xFFD}
    {a, s1} = Ids.monotonic_uuidv7(wrap, 0x1A0F)
    {b, s2} = Ids.monotonic_uuidv7(s1, 0x1A0F)
    {c, s3} = Ids.monotonic_uuidv7(s2, 0x1A0F)
    {d, s4} = Ids.monotonic_uuidv7(s3, 0x1A0F)

    assert s1.counter == 0xFFE
    assert s2.counter == 0xFFF
    assert s3 == %{last_ms: 0x1A0F + 1, counter: 0}
    assert s4 == %{last_ms: 0x1A0F + 1, counter: 1}
    assert a < b
    assert b < c
    assert c < d
    assert c =~ "000"
  end

  test "clock advance resets the counter; backward clock holds the timestamp" do
    {id1, seq1} = Ids.monotonic_uuidv7(%{last_ms: 100, counter: 7}, 200)
    assert seq1 == %{last_ms: 200, counter: 0}
    assert id1 =~ "000"

    {id2, seq2} = Ids.monotonic_uuidv7(seq1, 150)
    assert seq2 == %{last_ms: 200, counter: 1}
    assert id1 < id2
  end
end
