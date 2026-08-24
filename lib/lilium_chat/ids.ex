defmodule LiliumChat.Ids do
  @moduledoc """
  ID generation.

  `uuidv7/1` is a random-tail UUIDv7 (entity IDs, request IDs) — semantics
  copied from the old Worker's `src/ids/uuidv7.ts`: 48-bit millisecond
  timestamp + version nibble `7` + variant bits `0b10` + 72 random bits.
  Lexicographically sortable by time (contract §2.2).

  The per-channel *monotonic* event_id variant (`monotonicUuidV7`, 12-bit
  counter in rand_a) belongs to the per-channel writer process (spec §5.1,
  Phase 2); the per-channel writer process (`LiliumChat.Channel`) owns the
  counter and `parse_monotonic/1` recovers it from a stored event_id.
  """

  import Bitwise

  @doc "Random-tail UUIDv7 for `now_ms` (defaults to current time)."
  def uuidv7(now_ms \\ System.system_time(:millisecond)) do
    # Elixir's Integer.to_string/2 emits UPPERCASE hex — canonical UUIDs are lowercase.
    ms_hex = now_ms |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")

    <<r0, r1, r2, rest::binary>> = :crypto.strong_rand_bytes(10)
    # version: top nibble of the 7th byte (index 6 of the 16-byte UUID) -> 0x7
    r0 = Bitwise.band(r0, 0x0F) ||| 0x70
    # variant: top 2 bits of the 9th byte (index 8) -> 0b10
    r2 = Bitwise.band(r2, 0x3F) ||| 0x80

    hex = ms_hex <> Base.encode16(<<r0, r1, r2>> <> rest, case: :lower)
    format_uuid(hex)
  end

  @doc """
  Next monotonic per-channel event_id (old Worker `monotonicUuidV7`, spec §5.1).

  `seq` is `%{last_ms: integer, counter: integer}` (12-bit counter, capped at
  `0xFFF`). When `now_ms` advances past `last_ms` the counter resets to `0`;
  otherwise the counter increments (and the timestamp is held at `last_ms`) so
  the result stays strictly increasing within the channel even on a
  backward-clock tick. If the 12-bit counter is exhausted within one ms, the
  allocation rolls into the NEXT ms slot (counter 0) instead of wrapping to
  0 — strictly increasing in every case (the old Worker's 12-bit wrap is the
  same id space, "should not happen in practice"). Returns `{id, new_seq}` —
  the caller owns `seq`.
  """
  def monotonic_uuidv7(seq, now_ms \\ System.system_time(:millisecond)) do
    {ms, counter} =
      cond do
        now_ms > seq.last_ms ->
          {now_ms, 0}

        seq.counter < 0xFFF ->
          {seq.last_ms, seq.counter + 1}

        # counter exhausted for this ms: roll into the next ms slot
        true ->
          {seq.last_ms + 1, 0}
      end

    ms_hex = ms |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")

    # Encode as a FIXED 3-digit field (high nibble + 2-digit low byte). The
    # low byte must be zero-padded to 2 digits: a counter like 0x900 would
    # otherwise encode as "90" → padded to "090" → parse back as 0x090,
    # breaking lexicographic order and crash recovery.
    counter_hex =
      (Integer.to_string(Bitwise.band(Bitwise.bsr(counter, 8), 0x0F), 16) <>
         (Integer.to_string(Bitwise.band(counter, 0xFF), 16)
          |> String.downcase()
          |> String.pad_leading(2, "0")))
      |> String.downcase()

    <<b0, rest::binary>> = :crypto.strong_rand_bytes(8)
    b0 = Bitwise.band(b0, 0x3F) ||| 0x80
    rand_hex = Base.encode16(<<b0>> <> rest, case: :lower)

    {format_uuid(ms_hex <> "7" <> counter_hex <> rand_hex), %{last_ms: ms, counter: counter}}
  end

  @doc """
  The 16-byte binary form of a UUID string, for Postgres `uuid` columns.

  Untyped `Repo.query!` accepts only a 16-byte binary for a `uuid` column
  (neither a UUID string nor `%Ecto.UUID{}` — Postgrex DefaultTypes does not
  map `Ecto.UUID`).
  """
  def uuid_bytes(uuid) when is_binary(uuid) do
    uuid |> String.downcase() |> String.replace("-", "") |> :binary.decode_hex()
  end

  @doc """
  Recover the `%{last_ms, counter}` sequence state from a stored monotonic
  event_id (crash recovery, spec §5.1) — used to seed the in-process counter
  from `MAX(chat_v2.events.event_id)` for a channel.
  """
  def parse_monotonic(event_id) do
    hex = String.replace(event_id, "-", "")
    ms = hex |> String.slice(0, 12) |> String.to_integer(16)
    counter_field = String.slice(hex, 12, 4)
    counter_high = String.at(counter_field, 1) |> String.to_integer(16)
    counter_low = counter_field |> String.slice(2, 2) |> String.to_integer(16)
    %{last_ms: ms, counter: Bitwise.bor(Bitwise.bsl(counter_high, 8), counter_low)}
  end

  defp format_uuid(hex) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
