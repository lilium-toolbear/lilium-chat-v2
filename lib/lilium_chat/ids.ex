defmodule LiliumChat.Ids do
  @moduledoc """
  ID generation.

  `uuidv7/1` is a random-tail UUIDv7 (entity IDs, request IDs) — semantics
  copied from the old Worker's `src/ids/uuidv7.ts`: 48-bit millisecond
  timestamp + version nibble `7` + variant bits `0b10` + 72 random bits.
  Lexicographically sortable by time (contract §2.2).

  The per-channel *monotonic* event_id variant (`monotonicUuidV7`, 12-bit
  counter in rand_a) belongs to the per-channel writer process (spec §5.1,
  Phase 2) and is not defined here yet.
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

  defp format_uuid(hex) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
