defmodule LiliumChatWeb.CORS do
  @moduledoc """
  CORS for `/api/chat/*` — byte-for-byte parity with the old Worker (issue #2).

  The production Worker uses `hono/cors` (old repo `src/index.ts`) with:

      cors({
        origin: [...ALLOWED_BROWSER_ORIGINS],          // src/allowed-origins.ts
        allowMethods: ["GET", "POST", "PATCH", "PUT", "DELETE"],
        allowHeaders: ["Authorization", "Content-Type", "Idempotency-Key"],
        exposeHeaders: ["X-Request-Id"],
        credentials: false,
        maxAge: 86400,
      })

  This plug reproduces hono's exact observable behavior for that fixed config
  (verified against `hono/dist/middleware/cors/index.js`):

  * simple (non-OPTIONS) requests — always:
      - `access-control-expose-headers: X-Request-Id`
      - `vary: Origin`
    plus, only when the request `Origin` is whitelisted:
      - `access-control-allow-origin: <origin>` (mirrored)
  * OPTIONS requests — answered directly with **204 No Content** (empty body,
    no content-type/length) carrying the preflight set above plus:
      - `vary: Origin, Access-Control-Request-Headers`
      - `access-control-max-age: 86400`
      - `access-control-allow-methods: GET,POST,PATCH,PUT,DELETE`
      - `access-control-allow-headers: Authorization,Content-Type,Idempotency-Key`
    (preflight headers are sent even for a non-whitelisted origin; only
    `access-control-allow-origin` is then omitted — hono parity).

  The origin whitelist itself comes from config `:lilium_chat, :cors, :origins`
  (copied verbatim from old `src/allowed-origins.ts`, spec §6.3).
  """

  import Plug.Conn

  @behaviour Plug

  # Fixed by the production config (old src/index.ts) — not env-configurable there.
  @allow_methods "GET,POST,PATCH,PUT,DELETE"
  @allow_headers "Authorization,Content-Type,Idempotency-Key"
  @expose_headers "X-Request-Id"
  @max_age "86400"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{path_info: ["api", "chat" | _]} = conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first()
    allowed? = origin != nil and origin in allowed_origins()

    if conn.method == "OPTIONS" do
      conn
      |> maybe_put_allow_origin(origin, allowed?)
      |> put_resp_header("access-control-expose-headers", @expose_headers)
      # hono: set("Vary","Origin") then append("Access-Control-Request-Headers")
      |> put_resp_header("vary", "Origin, Access-Control-Request-Headers")
      |> put_resp_header("access-control-max-age", @max_age)
      |> put_resp_header("access-control-allow-methods", @allow_methods)
      |> put_resp_header("access-control-allow-headers", @allow_headers)
      |> delete_resp_header("content-length")
      |> delete_resp_header("content-type")
      |> send_resp(204, "")
      |> halt()
    else
      conn
      |> maybe_put_allow_origin(origin, allowed?)
      |> put_resp_header("access-control-expose-headers", @expose_headers)
      |> put_resp_header("vary", "Origin")
    end
  end

  @impl Plug
  def call(conn, _opts), do: conn

  defp maybe_put_allow_origin(conn, origin, true),
    do: put_resp_header(conn, "access-control-allow-origin", origin)

  defp maybe_put_allow_origin(conn, _origin, false), do: conn

  defp allowed_origins do
    Application.get_env(:lilium_chat, :cors)[:origins] || []
  end
end
