defmodule LiliumChatWeb.RequestId do
  @moduledoc """
  Request id middleware for `/api/chat/*` (issue #2).

  Copied from the old Worker `src/index.ts`:

      const requestId = c.req.header("X-Request-Id") ?? `req_${uuidv7()}`;
      c.set("requestId", requestId);
      c.header("X-Request-Id", requestId);

  i.e. echo an inbound `X-Request-Id` if present, otherwise mint
  `req_<uuidv7>` (contract §2.6: every HTTP response carries the header).
  Scoped to `/api/chat/*` exactly like the production middleware; other paths
  (e.g. static assets) are left untouched.

  The id is also stored in the process dictionary so the endpoint-level error
  fallback (`LiliumChatWeb.ErrorJSON`, which does not receive the conn) can
  include it in the envelope's `request_id` field.
  """

  import Plug.Conn

  @behaviour Plug

  @process_key :lilium_chat_request_id

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{path_info: ["api", "chat" | _]} = conn, _opts) do
    request_id =
      get_req_header(conn, "x-request-id") |> List.first() || "req_" <> LiliumChat.Ids.uuidv7()

    Process.put(@process_key, request_id)

    conn
    |> put_private(:lilium_chat_request_id, request_id)
    |> put_resp_header("x-request-id", request_id)
  end

  @impl Plug
  def call(conn, _opts), do: conn

  @doc "The current request id (set by this plug for `/api/chat/*` requests)."
  def current do
    Process.get(@process_key) || "req_" <> LiliumChat.Ids.uuidv7()
  end
end
