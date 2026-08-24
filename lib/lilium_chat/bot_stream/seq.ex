defmodule LiliumChat.BotStream.Seq do
  @moduledoc """
  Append sequence rules (contract §9.15.3, issue #18).

  * `ack_seq` — highest seq the server has **durable-flushed**.
  * `received_seq` — highest seq the **current connection** has accepted
    (may be ahead of `ack_seq`).
  * Gap = `received_seq + 1`, never `ack_seq + 1`.
  """

  @type verdict :: :durable_noop | :accept | :unacked_duplicate | :sequence_gap

  @doc """
  Classify an inbound append `seq` against the durable and connection
  watermarks. Keyword form matches the old Worker's `validateAppendSeq`.
  """
  def validate(opts) when is_list(opts) do
    validate(opts[:seq], opts[:ack_seq], opts[:received_seq])
  end

  def validate(seq, ack_seq, received_seq)
      when is_integer(seq) and is_integer(ack_seq) and is_integer(received_seq) do
    cond do
      seq <= ack_seq -> :durable_noop
      seq > received_seq + 1 -> :sequence_gap
      seq <= received_seq -> :unacked_duplicate
      true -> :accept
    end
  end
end
