defmodule LiliumChat.SlashTokens do
  @moduledoc """
  Slash-token normalization and collection (contract §9.3, issue #16).

  Verbatim port of the old Worker's `src/chat/slash-token.ts`. A slash token
  is the canonical or alias trigger for a bot command: trimmed, leading
  slashes stripped, NFKC-normalized and lowercased. Tokens are the global
  namespace enforced at catalog sync time (`bot_command_names`) — a name or
  alias colliding with another command's token is a `COMMAND_NAME_CONFLICT`.
  """

  @whitespace ~r/[\s]/u
  @control ~r/[\x00-\x1f\x7f]/

  @doc """
  Normalize a raw slash token: trim, strip leading `/`s, NFKC normalize,
  lowercase (`normalizeSlashToken`).
  """
  def normalize(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.replace(~r{^/+}, "")
    |> String.normalize(:nfkc)
    |> String.downcase()
  end

  @doc """
  Validate a single raw token. Returns `{:ok, token}` or
  `{:error, reason}` with reason one of `empty`, `too_long`,
  `invalid_characters` (`validateSlashToken`).
  """
  def validate(raw) when is_binary(raw) do
    token = normalize(raw)

    cond do
      token == "" ->
        {:error, "empty"}

      String.length(token) > 32 ->
        {:error, "too_long"}

      Regex.match?(@whitespace, token) ->
        {:error, "invalid_characters"}

      Regex.match?(@control, token) ->
        {:error, "invalid_characters"}

      String.contains?(token, "/") ->
        {:error, "invalid_characters"}

      true ->
        {:ok, token}
    end
  end

  @doc """
  Validate the canonical name plus aliases of one command and return the
  normalized forms. Returns

      {:ok, %{canonical: t, aliases: [t], all: [t]}}

  or `{:error, reason}` — `duplicate_in_request` when an alias equals the
  canonical name or a previous alias (`collectSlashTokens`).
  """
  def collect(name, aliases) when is_binary(name) and is_list(aliases) do
    case validate(name) do
      {:ok, canonical} ->
        results = Enum.map(aliases, &validate/1)

        case Enum.find_value(results, fn
               {:error, _} = error -> error
               _ -> nil
             end) do
          nil ->
            tokens = for {:ok, t} <- results, do: t
            all = [canonical | tokens]

            if Enum.uniq(all) != all do
              {:error, "duplicate_in_request"}
            else
              {:ok, %{canonical: canonical, aliases: tokens, all: all}}
            end

          error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end
end
