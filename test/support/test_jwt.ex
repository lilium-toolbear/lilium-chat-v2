defmodule LiliumChat.TestJWT do
  @moduledoc """
  Test helper: mint HS256 ToolBear-style JWTs against the app's configured
  `:jwt, :secret` (config/test.exs default: "test-only-jwt-secret").

  Mirrors the old repo's `test/helpers.ts` makeJwt and the conformance
  harness's `src/jwt.ts`.
  """

  @doc "The secret the app verifies against in this environment."
  def secret, do: Application.get_env(:lilium_chat, :jwt)[:secret]

  @doc """
  Sign `claims` (binary-key map) with HS256. Options:
    * `:secret` — override the signing secret (default: app config);
    * `:exp` — absolute Unix seconds expiry; pass `nil` for a token without
      an `exp` claim (default: now + 3600).
  """
  def sign(claims \\ %{}, opts \\ []) do
    secret = Keyword.get(opts, :secret) || secret()

    claims =
      cond do
        Keyword.has_key?(opts, :exp) and Keyword.get(opts, :exp) == nil ->
          Map.delete(claims, "exp")

        Keyword.has_key?(opts, :exp) ->
          Map.put(claims, "exp", Keyword.get(opts, :exp))

        true ->
          Map.put_new(claims, "exp", System.system_time(:second) + 3600)
      end

    signer = Joken.Signer.create("HS256", secret)

    case Joken.Signer.sign(claims, signer) do
      {:ok, token} -> token
      {:error, reason} -> raise "test JWT sign failed: #{inspect(reason)}"
    end
  end
end
