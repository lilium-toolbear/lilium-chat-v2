defmodule LiliumChatWeb.AdminBotsController do
  @moduledoc """
  Admin Bots API (contract §9.11, issue #16) — global bot list/detail/patch
  + token metadata/revoke. Browser JWT + `admin: true` on every route.

  Admin PATCH skips the ownership check; admin has NO `POST .../tokens`
  (token creation stays owner-scoped in §9.10).
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{Bots, Errors}
  alias LiliumChatWeb.ErrorHandler

  # -- GET /admin/bots ---------------------------------------------------------

  def index(conn, query) do
    result =
      with :ok <- require_admin(conn) do
        Bots.list_admin(%{
          limit: query["limit"],
          cursor: query["cursor"],
          q: query["q"],
          owner_user_id: query["owner_user_id"],
          status: query["status"],
          visibility: query["visibility"]
        })
      end

    respond(conn, result)
  end

  # -- GET /admin/bots/{bot_id} -------------------------------------------------

  def show(conn, %{"bot_id" => bot_id}) do
    result =
      with :ok <- require_admin(conn), {:ok, %{bot: bot}} <- Bots.get(bot_id) do
        if bot["status"] == "deleted" do
          {:error, Errors.new("BOT_NOT_FOUND", "bot not found")}
        else
          {:ok, %{bot: bot}}
        end
      end

    respond(conn, result)
  end

  # -- PATCH /admin/bots/{bot_id} ------------------------------------------------

  def update(conn, %{"bot_id" => bot_id}) do
    body = conn.body_params

    result =
      with :ok <- require_admin(conn),
           :ok <- require_idempotency_key(conn),
           {:ok, %{bot: bot}} <- Bots.get(bot_id),
           :ok <- not_deleted(bot),
           :ok <- at_least_one_field?(body),
           :ok <- display_name_valid?(body) do
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
      with :ok <- require_admin(conn),
           {:ok, %{bot: bot}} <- Bots.get(bot_id),
           :ok <- not_deleted(bot) do
        Bots.list_tokens(bot_id)
      end

    respond(conn, result)
  end

  def revoke_token(conn, %{"bot_id" => bot_id, "token_id" => token_id}) do
    result =
      with :ok <- require_admin(conn),
           :ok <- require_idempotency_key(conn),
           {:ok, %{bot: bot}} <- Bots.get(bot_id),
           :ok <- not_deleted(bot) do
        Bots.revoke_token(bot_id, token_id)
      end

    respond(conn, result)
  end

  # -- helpers -------------------------------------------------------------------

  defp require_admin(conn) do
    if conn.assigns.identity.is_admin do
      :ok
    else
      {:error, Errors.new("ADMIN_ACCESS_REQUIRED", "Admin access required")}
    end
  end

  defp not_deleted(bot) do
    if bot["status"] == "deleted" do
      {:error, Errors.new("BOT_NOT_FOUND", "bot not found")}
    else
      :ok
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

  defp require_idempotency_key(conn) do
    case Plug.Conn.get_req_header(conn, "idempotency-key") |> List.first() do
      nil -> {:error, Errors.new("INVALID_MESSAGE", "Idempotency-Key required")}
      "" -> {:error, Errors.new("INVALID_MESSAGE", "Idempotency-Key required")}
      _key -> :ok
    end
  end

  defp respond(conn, result) do
    case result do
      {:ok, body} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, %Errors.ApiError{} = api_error} ->
        ErrorHandler.render(conn, api_error)

      other ->
        raise "unexpected admin bots result: #{inspect(other)}"
    end
  end
end
