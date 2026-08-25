defmodule LiliumChatWeb.BotsController do
  @moduledoc """
  Developer Bots API (contract §9.10, issue #16) — owner-scoped CRUD on
  `bot_apps` + token lifecycle. Browser JWT; ownership checked per call
  (old `getOwnedBot`: non-owner → `403 FORBIDDEN "bot access denied"` first,
  then deleted → `404 BOT_NOT_FOUND`).
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{Bots, Errors}
  alias LiliumChatWeb.ErrorHandler

  # -- POST /bots -------------------------------------------------------------

  def create(conn, _params) do
    identity = conn.assigns.identity
    body = conn.body_params

    result =
      with :ok <- require_idempotency_key(conn),
           :ok <- display_name_present?(body),
           :ok <- visibility_admin?(body["visibility"], identity.is_admin) do
        Bots.create(identity.user_id, attrs_from_body(body))
        |> wrap_create()
      end

    respond(conn, result)
  end

  defp display_name_present?(body) do
    if is_binary(body["display_name"]) and String.trim(body["display_name"]) != "" do
      :ok
    else
      {:error, Errors.new("INVALID_MESSAGE", "display_name required")}
    end
  end

  defp visibility_admin?(visibility, is_admin) do
    if visibility == "official" and not is_admin do
      {:error,
       Errors.new("ADMIN_ACCESS_REQUIRED", "Admin access required to set visibility to official")}
    else
      :ok
    end
  end

  defp attrs_from_body(body) do
    %{
      display_name: body["display_name"],
      avatar_url: body["avatar_url"],
      description: body["description"],
      visibility: body["visibility"] || "private",
      issue_initial_token: Map.get(body, "issue_initial_token", true),
      initial_token_name: body["initial_token_name"],
      initial_token_expires_at: body["initial_token_expires_at"]
    }
  end

  # Create omits `initial_token` from the JSON when no token was issued
  # (JS `undefined` key).
  defp wrap_create({:ok, %{bot: bot, initial_token: nil}}), do: {:ok, 201, %{bot: bot}}

  defp wrap_create({:ok, %{bot: bot, initial_token: token}}),
    do: {:ok, 201, %{bot: bot, initial_token: token}}

  defp wrap_create({:error, _} = err), do: err

  # -- GET /bots --------------------------------------------------------------

  def index(conn, query) do
    result =
      Bots.list_for_owner(conn.assigns.identity.user_id, %{
        limit: query["limit"],
        cursor: query["cursor"]
      })

    respond(conn, result)
  end

  # -- GET /bots/{bot_id} ------------------------------------------------------

  def show(conn, %{"bot_id" => bot_id}) do
    identity = conn.assigns.identity

    result =
      with {:ok, bot} <- lookup_bot(bot_id),
           :ok <- check_owned(bot, identity.user_id) do
        {:ok, %{bot: bot}}
      end

    respond(conn, result)
  end

  # -- PATCH /bots/{bot_id} ----------------------------------------------------

  def update(conn, %{"bot_id" => bot_id}) do
    identity = conn.assigns.identity
    body = conn.body_params

    result =
      with :ok <- require_idempotency_key(conn),
           {:ok, bot} <- lookup_bot(bot_id),
           :ok <- check_owned(bot, identity.user_id),
           :ok <- at_least_one_field?(body),
           :ok <- display_name_valid?(body),
           :ok <- visibility_admin?(body["visibility"], identity.is_admin) do
        changes =
          for field <-
                ["display_name", "avatar_url", "description", "visibility", "status"],
              Map.has_key?(body, field),
              do: {field, body[field]}

        Bots.update(bot_id, changes)
      end

    respond(conn, result)
  end

  # -- tokens ------------------------------------------------------------------

  def list_tokens(conn, %{"bot_id" => bot_id}) do
    result =
      with {:ok, bot} <- lookup_bot(bot_id),
           :ok <- check_owned(bot, conn.assigns.identity.user_id) do
        Bots.list_tokens(bot_id)
      end

    respond(conn, result)
  end

  def create_token(conn, %{"bot_id" => bot_id}) do
    identity = conn.assigns.identity
    body = conn.body_params

    result =
      with :ok <- require_idempotency_key(conn),
           {:ok, bot} <- lookup_bot(bot_id),
           :ok <- check_owned(bot, identity.user_id),
           :ok <- token_name_present?(body) do
        Bots.create_token(bot_id, %{
          name: body["name"],
          scopes: body["scopes"],
          expires_at: body["expires_at"]
        })
        |> wrap_token_created()
      end

    respond(conn, result)
  end

  def revoke_token(conn, %{"bot_id" => bot_id, "token_id" => token_id}) do
    result =
      with :ok <- require_idempotency_key(conn),
           {:ok, bot} <- lookup_bot(bot_id),
           :ok <- check_owned(bot, conn.assigns.identity.user_id) do
        Bots.revoke_token(bot_id, token_id)
      end

    respond(conn, result)
  end

  # -- helpers -----------------------------------------------------------------

  # Old Worker parity (issue #27 batch D): these routes look the bot up on
  # the singleton BotRegistry via a DO stub RPC; a LOOKUP MISS surfaces as an
  # untyped remote error → the worker-wide catch-all CHAT_WORKER_UNAVAILABLE
  # (old `src/index.ts`: unknown error → `worker temporarily unavailable`),
  # while a DELETED bot is an explicit local ApiError(BOT_NOT_FOUND) → 404
  # (checked below). Contract §9.10/§9.11 enumerate no per-route errors, so
  # the reference wire behavior is pinned.
  defp lookup_bot(bot_id) do
    case Bots.get(bot_id) do
      {:ok, %{bot: bot}} ->
        {:ok, bot}

      {:error, _} ->
        {:error, Errors.new("CHAT_WORKER_UNAVAILABLE", "worker temporarily unavailable")}
    end
  end

  # Old Worker `createBotTokenHandler` answers 201 (§9.10 is silent on the
  # status; the reference implementation wins).
  defp wrap_token_created({:ok, %{token: token}}), do: {:ok, 201, %{token: token}}

  defp wrap_token_created({:error, _} = err), do: err

  # Old `getOwnedBot` order: non-owner FORBIDDEN first, then deleted.
  defp check_owned(bot, user_id) do
    cond do
      bot["owner_user_id"] != user_id -> {:error, Errors.new("FORBIDDEN", "bot access denied")}
      bot["status"] == "deleted" -> {:error, Errors.new("BOT_NOT_FOUND", "bot not found")}
      true -> :ok
    end
  end

  defp at_least_one_field?(body) do
    fields = ["display_name", "avatar_url", "description", "visibility", "status"]

    if Enum.any?(fields, &Map.has_key?(body, &1)) do
      :ok
    else
      {:error, Errors.new("INVALID_MESSAGE", "at least one field required")}
    end
  end

  defp display_name_valid?(body) do
    if Map.has_key?(body, "display_name") and
         not (is_binary(body["display_name"]) and String.trim(body["display_name"]) != "") do
      {:error, Errors.new("INVALID_MESSAGE", "display_name invalid")}
    else
      :ok
    end
  end

  defp token_name_present?(body) do
    if is_binary(body["name"]) and String.trim(body["name"]) != "" do
      :ok
    else
      {:error, Errors.new("INVALID_MESSAGE", "token name required")}
    end
  end

  defp require_idempotency_key(conn) do
    case Plug.Conn.get_req_header(conn, "idempotency-key") |> List.first() do
      nil -> {:error, Errors.new("INVALID_MESSAGE", "Idempotency-Key required")}
      "" -> {:error, Errors.new("INVALID_MESSAGE", "Idempotency-Key required")}
      _key -> :ok
    end
  end

  defp respond(conn, result) do
    case result do
      {:ok, status, body} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(status, Jason.encode!(body))

      {:ok, body} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, %Errors.ApiError{} = api_error} ->
        ErrorHandler.render(conn, api_error)

      other ->
        raise "unexpected bots result: #{inspect(other)}"
    end
  end
end
