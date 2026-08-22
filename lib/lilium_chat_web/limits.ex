defmodule LiliumChatWeb.Limits do
  @moduledoc """
  Parsing of `limit` query parameters, mirroring the old Worker's route
  handlers (issue #7): all paged read endpoints clamp `limit` to 1..100 with
  a default of 50, but the old Worker parses it differently per handler:

  * the directory handler uses `parseInt(limit, 10)` — explicit radix 10, so
    only a leading sign + decimal digits count (`"0x10"` → 0, `"4.2"` → 4,
    `"abc"` → NaN → 50);
  * the members/stickers handlers use `Number(limit)` — a full JS numeric
    literal (decimal, fraction/exponent, `0x`/`0b`/`0o` integers, `1_000`
    numeric separators, `Infinity`, `NaN`); anything else is NaN → 50.

  Both are reproduced here so degenerate inputs behave like the old Worker
  (fractional limits truncate via `slice(0, limit)` / `LIMIT` downstream).
  """

  @min 1
  @max 100
  @default 50

  # A JS decimal numeric literal: optional sign, digits with an optional
  # fraction, optional exponent. (Integer separator literals and radix
  # literals are handled by their own branches before this is consulted.)
  @decimal_re ~r/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/

  @doc "Directory `limit` (JS `parseInt` semantics, clamped 1..100)."
  def parse_int_limit(nil), do: @default

  def parse_int_limit(raw) when is_binary(raw) do
    case Regex.run(~r/^[+-]?\d+/, String.trim_leading(raw)) do
      [match | _] -> clamp(String.to_integer(match))
      _ -> @default
    end
  end

  @doc "Members/stickers `limit` (JS `Number` semantics, clamped 1..100, truncated)."
  def parse_num_limit(nil), do: @default

  def parse_num_limit(raw) when is_binary(raw) do
    case js_number(String.trim(raw)) do
      :nan -> @default
      value -> clamp(value)
    end
  end

  # Emulate the old Worker's `Number(limit)`: the whole (trimmed) string must
  # be a JS numeric literal — decimal (fraction/exponent), hex/binary/octal,
  # `1_000`-style numeric separators, or `Infinity`/`NaN`. Anything else is
  # `:nan` (→ default 50, as the old Worker's `Number(...)` yields NaN).
  defp js_number(""), do: 0
  defp js_number("Infinity"), do: :infinity
  defp js_number("+Infinity"), do: :infinity
  defp js_number("-Infinity"), do: :neg_infinity
  defp js_number("NaN"), do: :nan

  defp js_number(s) do
    cond do
      String.match?(s, ~r/^[+-]?0[xX][0-9a-fA-F]+$/) ->
        parse_radix_literal(s, 16)

      String.match?(s, ~r/^[+-]?0[bB][01]+$/) ->
        parse_radix_literal(s, 2)

      String.match?(s, ~r/^[+-]?0[oO][0-7]+$/) ->
        parse_radix_literal(s, 8)

      # Integer literal, with ES2021 numeric separators (`1_000`): a digit,
      # then any run of (a digit | an underscore-digit). This rejects
      # `1__0`, `1_`, and `_1` exactly as JS `Number()` does.
      String.match?(s, ~r/^[+-]?\d(\d|_\d)*$/) ->
        s |> String.replace("_", "") |> String.to_integer()

      # Decimal literal (optional fraction/exponent). A valid decimal that
      # `Float.parse/1` rejects is an out-of-range overflow → ±Infinity, as
      # JS `Number("1e400") === Infinity`.
      String.match?(s, @decimal_re) ->
        decimal_or_infinity(s)

      true ->
        :nan
    end
  end

  # Parse a validated decimal literal; out-of-range values become ±Infinity.
  defp decimal_or_infinity(s) do
    case Float.parse(s) do
      {value, ""} when is_float(value) or is_integer(value) ->
        value

      _ ->
        if String.starts_with?(s, "-"), do: :neg_infinity, else: :infinity
    end
  end

  # `0x`/`0b`/`0o` integer literal → its value (sign preserved).
  defp parse_radix_literal(s, radix) do
    sign = if String.starts_with?(s, "-"), do: -1, else: 1
    digits = s |> String.replace(~r/^[+-]/, "") |> String.replace(~r/^0[xXbBoO]/, "")
    sign * String.to_integer(digits, radix)
  end

  # Clamp to the 1..100 window, then truncate fractions (the old Worker's
  # `slice(0, limit)` / PG `LIMIT` do the same downstream).
  #
  # ±Infinity are mapped explicitly: in Elixir the infinity atoms order as
  # plain atoms under `Kernel.max/2`/`min/2` (not as numbers), so comparing
  # them against the window would mis-clamp.
  defp clamp(:infinity), do: @max
  defp clamp(:neg_infinity), do: @min

  defp clamp(value) do
    value
    |> Kernel.max(@min)
    |> Kernel.min(@max)
    |> trunc()
  end
end
