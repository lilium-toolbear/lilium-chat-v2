defmodule LiliumChat.CanonicalJSON do
  @moduledoc """
  Deterministic JSON encoding that matches JavaScript `JSON.stringify`
  byte-for-byte for the shapes the bot domain hashes (issue #16).

  The old Worker computes `definition_hash` and idempotency `request_hash`
  over `JSON.stringify(...)` of command definitions. For those hashes to be
  identical across implementations, the canonical byte form must be
  identical: insertion-ordered object keys, no whitespace, the same string
  escapes and the same number formatting.

  Representation convention (so key order is explicit, unlike Elixir maps):

  * an object is a list of `{key, value}` tuples in key order;
  * an array is a plain list of values;
  * primitives are binaries, integers, floats, booleans, nil.
  """

  @doc """
  Encode a canonical value to a JSON binary.
  """
  def encode(value), do: do_encode(value)

  @doc """
  Encode then SHA-256 (lowercase hex) — the worker's `sha256Hex` over
  canonical JSON.
  """
  def encode_and_sha256(value) do
    encoded = do_encode(value)
    digest = :crypto.hash(:sha256, encoded)
    Base.encode16(digest, case: :lower)
  end

  defp do_encode(fields) when is_list(fields) do
    if object?(fields) do
      fields
      |> Enum.map(fn {key, value} -> "\"" <> escape(key) <> "\":" <> do_encode(value) end)
      |> Enum.join(",")
      |> then(&("{" <> &1 <> "}"))
    else
      "[" <> Enum.map_join(fields, ",", &do_encode/1) <> "]"
    end
  end

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(value) when is_integer(value), do: Integer.to_string(value)
  defp do_encode(value) when is_float(value), do: json_float(value)
  defp do_encode(value) when is_binary(value), do: json_string(value)

  # -- key/value detection ---------------------------------------------------

  # An object is a NON-EMPTY list whose first element is a `{string, _}`
  # tuple and every element is a 2-tuple. (An empty list is an empty array;
  # arrays of field lists are detected by their non-tuple heads.)
  defp object?(fields) do
    case List.first(fields) do
      {key, _} when is_binary(key) ->
        Enum.all?(fields, fn field -> is_tuple(field) and tuple_size(field) == 2 end)

      _ ->
        false
    end
  end

  # -- strings ---------------------------------------------------------------

  # JS JSON.stringify escaping: \" \\ \b \f \n \r \t plus \uXXXX for the
  # remaining control characters; non-ASCII passes through verbatim.
  defp json_string(string) do
    "\"" <> escape(string) <> "\""
  end

  defp escape(string) do
    string
    |> String.to_charlist()
    |> Enum.map(fn
      ?" -> "\\\""
      ?\\ -> "\\\\"
      ?\b -> "\\b"
      ?\f -> "\\f"
      ?\n -> "\\n"
      ?\r -> "\\r"
      ?\t -> "\\t"
      char when char < 0x20 -> "\\u" <> pad4(Integer.to_string(char, 16))
      # re-encode the codepoint as UTF-8 (a bare `<<char>>` would emit the
      # big-endian integer bytes for codepoints above 0xFF).
      char -> <<char::utf8>>
    end)
    |> IO.iodata_to_binary()
  end

  defp pad4(hex) do
    String.pad_leading(hex, 4, "0")
  end

  # -- floats ----------------------------------------------------------------

  # JS `String(number)`: integral floats drop the fraction ("1.0" -> "1");
  # otherwise the shortest round-trip representation.
  defp json_float(value) do
    if value == trunc(value) and abs(value) < 1.0e15 do
      Integer.to_string(trunc(value))
    else
      Float.to_string(value)
    end
  end
end
