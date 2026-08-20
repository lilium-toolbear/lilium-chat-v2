defmodule LiliumChatWeb.HealthController do
  use LiliumChatWeb, :controller

  alias Ecto.Adapters.SQL
  alias LiliumChat.Repo

  @doc """
  Liveness probe. Also verifies DB connectivity (one cheap query).
  """
  def show(conn, _params) do
    db_ok? =
      try do
        SQL.query!(Repo, "SELECT 1", [])
        true
      rescue
        e ->
          {:error, Exception.message(e)}
      end

    status = if db_ok? == true, do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{
      status: if(db_ok? == true, do: "ok", else: "degraded"),
      db: db_ok?
    })
  end
end
