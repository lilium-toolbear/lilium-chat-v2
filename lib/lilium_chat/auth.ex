defmodule LiliumChat.Auth do
  @moduledoc """
  Browser JWT verification (spec §6.1 / contract §2.1, issue #2).

  ToolBear-issued HS256 tokens verified against the shared `JWT_SECRET`
  (config `:lilium_chat, :jwt, :secret`). Rules copied verbatim from the old
  Worker's `src/auth/jwt.ts`:

    * signature valid (HS256 only), `exp` not expired;
    * `sub` required — non-empty string, else `UNAUTHORIZED`;
    * `client_id` present (not null) → `MACHINE_TOKEN_NOT_ALLOWED`;
    * `managed_session === true`, or `owner_user_id` / `effective_account_user_id`
      present with a JS-stringified value different from `sub`
      → `SESSION_NOT_ALLOWED`;
    * `admin === true` (strict) → identity is admin.

  The order of checks mirrors the reference implementation exactly.
  """

  alias LiliumChat.Errors

  defmodule Identity do
    @moduledoc "Verified browser identity (contract §2.1)."
    defstruct [:user_id, :is_admin]
  end

  @type t :: %Identity{user_id: String.t(), is_admin: boolean()}

  @doc """
  Verify a browser JWT. Returns `{:ok, identity}` or
  `{:error, %LiliumChat.Errors.ApiError{}}`.
  """
  def verify(token, secret) when is_binary(token) and is_binary(secret) do
    if byte_size(secret) == 0 do
      {:error, Errors.new("UNAUTHORIZED", "Invalid or expired token")}
    else
      signer = Joken.Signer.create("HS256", secret)

      case Joken.verify(token, signer) do
        {:ok, claims} -> check_claims(claims)
        {:error, _reason} -> {:error, Errors.new("UNAUTHORIZED", "Invalid or expired token")}
      end
    end
  end

  def verify(_token, _secret),
    do: {:error, Errors.new("UNAUTHORIZED", "Invalid or expired token")}

  defp check_claims(claims) do
    now = System.system_time(:second)
    sub = claims["sub"]

    cond do
      # jose (JS) validates exp/nbf during jwtVerify — Joken does not, so we
      # replicate its semantics: present + non-finite → invalid; otherwise the
      # time comparison below.
      not valid_exp?(claims, now) or not valid_nbf?(claims, now) ->
        {:error, Errors.new("UNAUTHORIZED", "Invalid or expired token")}

      not (is_binary(sub) and byte_size(sub) > 0) ->
        {:error, Errors.new("UNAUTHORIZED", "Invalid or expired token")}

      # NOTE: JOSE decodes JSON null as the atom :null — treat it like nil.
      Map.has_key?(claims, "client_id") and claims["client_id"] not in [nil, :null] ->
        {:error, Errors.new("MACHINE_TOKEN_NOT_ALLOWED")}

      claims["managed_session"] == true or
        (Map.has_key?(claims, "owner_user_id") and js_string(claims["owner_user_id"]) != sub) or
          (Map.has_key?(claims, "effective_account_user_id") and
             js_string(claims["effective_account_user_id"]) != sub) ->
        {:error, Errors.new("SESSION_NOT_ALLOWED")}

      true ->
        {:ok, %Identity{user_id: sub, is_admin: claims["admin"] == true}}
    end
  end

  defp valid_exp?(claims, now) do
    case claims["exp"] do
      nil -> true
      :null -> false
      n when is_integer(n) or is_float(n) -> now <= n
      _ -> false
    end
  end

  defp valid_nbf?(claims, now) do
    case claims["nbf"] do
      nil -> true
      :null -> false
      n when is_integer(n) or is_float(n) -> now >= n
      _ -> false
    end
  end

  # JS `String(value)` semantics for the owner/effective-account comparison
  # (src/auth/jwt.ts uses `String(payload.owner_user_id) !== sub`). JOSE
  # decodes JSON null as :null.
  defp js_string(nil), do: "null"
  defp js_string(:null), do: "null"
  defp js_string(true), do: "true"
  defp js_string(false), do: "false"
  defp js_string(n) when is_integer(n), do: Integer.to_string(n)
  defp js_string(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 20)
  defp js_string(b) when is_binary(b), do: b
  defp js_string(other), do: inspect(other)
end
