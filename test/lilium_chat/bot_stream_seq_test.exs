defmodule LiliumChat.BotStream.SeqTest do
  @moduledoc """
  Append seq rules (contract §9.15.3, issue #18).

  Gap uses `received_seq + 1`, not `ack_seq + 1`. Durable no-op is
  `seq <= ack_seq`. Unacked duplicates live between `ack_seq` and
  `received_seq`.
  """

  use ExUnit.Case, async: true

  alias LiliumChat.BotStream.Seq

  test "seq == received_seq + 1 is accept (even when ack_seq lags)" do
    assert Seq.validate(seq: 1, ack_seq: 0, received_seq: 0) == :accept
    assert Seq.validate(seq: 3, ack_seq: 1, received_seq: 2) == :accept
  end

  test "seq <= ack_seq is durable_noop" do
    assert Seq.validate(seq: 0, ack_seq: 0, received_seq: 0) == :durable_noop
    assert Seq.validate(seq: 2, ack_seq: 2, received_seq: 4) == :durable_noop
    assert Seq.validate(seq: 1, ack_seq: 3, received_seq: 3) == :durable_noop
  end

  test "seq > received_seq + 1 is sequence_gap (not compared to ack_seq)" do
    # ack_seq=0, received_seq=0, seq=2 → gap (missing 1)
    assert Seq.validate(seq: 2, ack_seq: 0, received_seq: 0) == :sequence_gap
    # ack_seq lags; gap is still vs received_seq
    assert Seq.validate(seq: 5, ack_seq: 1, received_seq: 3) == :sequence_gap
  end

  test "ack_seq < seq <= received_seq is unacked_duplicate" do
    assert Seq.validate(seq: 2, ack_seq: 1, received_seq: 3) == :unacked_duplicate
    assert Seq.validate(seq: 3, ack_seq: 1, received_seq: 3) == :unacked_duplicate
  end
end
