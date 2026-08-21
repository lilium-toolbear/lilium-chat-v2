defmodule LiliumChatWeb.RequestIdTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias LiliumChatWeb.RequestId

  @req_id_re ~r/^req_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defp run(method, path, headers) do
    conn =
      conn(method, path)
      |> apply_headers(headers)

    opts = RequestId.init([])
    RequestId.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  test "mints req_<uuidv7> when no inbound header (old Worker parity)" do
    conn = run(:get, "/api/chat/channels", [])
    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ @req_id_re
    assert conn.private[:lilium_chat_request_id] == id
  end

  test "echoes an inbound X-Request-Id verbatim (old Worker parity)" do
    conn = run(:get, "/api/chat/channels", [{"x-request-id", "req_client-supplied"}])
    assert get_resp_header(conn, "x-request-id") == ["req_client-supplied"]
    assert conn.private[:lilium_chat_request_id] == "req_client-supplied"
  end

  test "non-/api/chat paths are untouched (production middleware scope)" do
    conn = run(:get, "/favicon.ico", [])
    assert get_resp_header(conn, "x-request-id") == []
    assert conn.private[:lilium_chat_request_id] == nil
  end

  test "current/0 falls back to a fresh id outside requests" do
    assert RequestId.current() =~ @req_id_re
  end
end
