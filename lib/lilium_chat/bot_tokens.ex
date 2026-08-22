defmodule LiliumChat.BotTokens do
  @moduledoc """
  Bot token hashing and verification (contract §6.1 / §9.10, issue #16).

  Bot tokens authenticate bot-to-server calls with
  `Authorization: Bearer <token>`. The plaintext is `lcbot_` + 32 random
  bytes base64url-encoded; only the lowercase hex SHA-256 is stored
  (`bot_tokens.token_hash`, UNIQUE). The plaintext is returned to the
  caller exactly once (at create / initial-token time) and is never
  recoverable afterwards.
  """

  alias LiliumChat.{Errors, Query, Repo}

  @default_scopes ["chat:runtime:connect", "chat:commands:manage"]

  @doc """
  Lowercase hex SHA-256 of the plaintext token (`hashBotToken`).
  """
  def hash(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  @doc """
  Generate a new plaintext bot token: `lcbot_` + base64url(32 random bytes).
  """
  def generate_plaintext() do
    "lcbot_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc """
  Scopes issued with a new bot's initial token.
  """
  def default_scopes(), do: @default_scopes

  @doc """
  Scopes stored as a JSON array string in `bot_tokens.scopes`.
  """
  def scopes_json(scopes) when is_list(scopes) do
    scopes |> Jason.encode!()
  end

  @doc """
  Parse the stored scopes column back into a list of strings.
  """
  def scopes_from_stored(stored) when is_binary(stored) do
    case Jason.decode(stored) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def scopes_from_stored(_), do: []

  @doc """
  Verify a bearer token and resolve its scopes.

  Returns `{:ok, %{bot_id: id, scopes: [scope]}}` or
  `{:error, %LiliumChat.Errors.ApiError{}}` (`UNAUTHORIZED "Invalid bot
  token"` for unknown / revoked / expired tokens or an inactive bot).
  """
  def verify(plaintext) when is_binary(plaintext) do
    hash = hash(plaintext)

    rows =
      Repo.query(
        """
        SELECT t.bot_id, t.scopes, t.revoked_at, t.expires_at, a.status
        FROM chat_v2.bot_tokens t
        JOIN chat_v2.bot_apps a ON a.bot_id = t.bot_id
        WHERE t.token_hash = $1
        """,
        [hash],
        type: true
      )
      |> Query.rows()

    case List.first(rows) do
      nil ->
        {:error, Errors.new("UNAUTHORIZED", "Invalid bot token")}

      row ->
        active? =
          row["status"] == "active" and
            is_nil(row["revoked_at"]) and
            (is_nil(row["expires_at"]) or row["expires_at"] > DateTime.utc_now())

        if active? do
          {:ok, %{bot_id: row["bot_id"], scopes: scopes_from_stored(row["scopes"])}}
        else
          {:error, Errors.new("UNAUTHORIZED", "Invalid bot token")}
        end
    end
  end
end
