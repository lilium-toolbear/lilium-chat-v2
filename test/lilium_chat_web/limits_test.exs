defmodule LiliumChatWeb.LimitsTest do
  @moduledoc """
  Unit tests for `LiliumChatWeb.Limits` (issue #7): the two `limit` parsers
  must reproduce the old Worker's exact semantics — `parseInt(x, 10)` for the
  directory, `Number(x)` for members/stickers — including the degenerate
  inputs that differ between the two JS built-ins.
  """

  use ExUnit.Case, async: true

  alias LiliumChatWeb.Limits

  # ------------------------------------------------------------------ parseInt

  test "parse_int_limit mirrors parseInt(x, 10): leading digits, NaN → 50" do
    assert Limits.parse_int_limit(nil) == 50
    assert Limits.parse_int_limit("50") == 50
    assert Limits.parse_int_limit("  42  ") == 42
    assert Limits.parse_int_limit("+10") == 10
    assert Limits.parse_int_limit("250") == 100

    # Explicit radix 10: "0x10" reads only the leading "0" → 0 → clamp 1
    # (NOT 16 — that would be auto-radix parseInt).
    assert Limits.parse_int_limit("0x10") == 1

    # Fractional / separator inputs stop at the first non-digit.
    assert Limits.parse_int_limit("4.2") == 4
    assert Limits.parse_int_limit("1_000") == 1

    # Out-of-window clamps; NaN (no leading digits) → default 50.
    assert Limits.parse_int_limit("-5") == 1
    assert Limits.parse_int_limit("0") == 1
    assert Limits.parse_int_limit("") == 50
    assert Limits.parse_int_limit("abc") == 50
  end

  # -------------------------------------------------------------------- Number

  test "parse_num_limit mirrors Number(x): full numeric literal, NaN → 50" do
    assert Limits.parse_num_limit(nil) == 50

    # Number("") === 0 → clamps to the minimum.
    assert Limits.parse_num_limit("") == 1

    assert Limits.parse_num_limit("50") == 50
    assert Limits.parse_num_limit("42.5") == 42
    assert Limits.parse_num_limit("0.5") == 1
    assert Limits.parse_num_limit("1e2") == 100

    # Numeric separators, radix literals and Infinity (all NaN for parseInt
    # parity cases above, but real numbers under Number).
    assert Limits.parse_num_limit("1_000") == 100
    # Invalid separator placements are NaN, as in JS.
    assert Limits.parse_num_limit("1__0") == 50
    assert Limits.parse_num_limit("1_") == 50
    assert Limits.parse_num_limit("_1") == 50
    assert Limits.parse_num_limit("0x10") == 16
    assert Limits.parse_num_limit("0b101") == 5
    assert Limits.parse_num_limit("0o17") == 15
    assert Limits.parse_num_limit("Infinity") == 100
    assert Limits.parse_num_limit("-Infinity") == 1

    # Non-literals → NaN → default 50; huge values clamp.
    assert Limits.parse_num_limit("NaN") == 50
    assert Limits.parse_num_limit("42px") == 50
    assert Limits.parse_num_limit("99999999999999999999") == 100
    assert Limits.parse_num_limit("1e400") == 100
  end
end
