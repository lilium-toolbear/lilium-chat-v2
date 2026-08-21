defmodule LiliumChatWeb.BootstrapControllerTest do
  @moduledoc """
  Full-endpoint integration tests for GET /api/chat/bootstrap (issue #5).

  Runs real conns through the ENTIRE endpoint pipeline (CORS plug →
  RequestId plug → router → AuthPlug → controller), verifying:
  * auth required (401 without token)
  * correct wire shape (contract §4.1)
  * X-Request-Id header
  * content-type
  * optional ?channel_id= parameter
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT

  @origin "https://lilium.kuma.homes"
  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  defp request(method, path, headers) do
    conn =
      Plug.Test.conn(method, path)
      |> apply_headers(headers)

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp auth_headers(claims \\ %{}, opts \\ []) do
    [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @uid), opts)}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  # ---------------------------------------------------------------- tests

  test "no Authorization header → 401 UNAUTHORIZED" do
    conn = request(:get, "/api/chat/bootstrap", [{"origin", @origin}])

    assert conn.status == 401
    json = body_json(conn)
    assert json["error"]["code"] == "UNAUTHORIZED"
    assert get_resp_header(conn, "x-request-id") != []
  end

  test "valid token → 200 with correct wire shape (empty state)" do
    headers = [{"origin", @origin} | auth_headers()]
    conn = request(:get, "/api/chat/bootstrap", headers)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_/

    json = body_json(conn)

    # me
    assert json["me"]["user_id"] == @uid
    assert json["me"]["display_name"] != nil
    assert json["me"]["avatar_url"] == nil

    # channels
    assert json["channels"] == []

    # active_channel
    assert json["active_channel"] == nil

    # messages
    assert json["messages"]["items"] == []
    assert json["messages"]["next_cursor"] == nil

    # channel_pins
    assert json["channel_pins"] == []

    # event_state
    assert json["event_state"]["per_channel"] == %{}
  end

  test "valid token with ?channel_id= → 200 (unknown channel, still valid)" do
    unknown = "99999999-9999-7999-8999-999999999999"
    headers = [{"origin", @origin} | auth_headers()]
    conn = request(:get, "/api/chat/bootstrap?channel_id=#{unknown}", headers)

    assert conn.status == 200
    json = body_json(conn)
    # Unknown channel → active_channel is nil
    assert json["active_channel"] == nil
    assert json["messages"]["items"] == []
  end

  test "machine token → 401 MACHINE_TOKEN_NOT_ALLOWED" do
    headers = [
      {"origin", @origin},
      {"authorization", "Bearer " <> sign(%{"sub" => @uid, "client_id" => "bot-1"})}
    ]

    conn = request(:get, "/api/chat/bootstrap", headers)
    assert conn.status == 401

    json = body_json(conn)
    assert json["error"]["code"] == "MACHINE_TOKEN_NOT_ALLOWED"
  end

  test "managed session → 403 SESSION_NOT_ALLOWED" do
    headers = [
      {"origin", @origin},
      {"authorization", "Bearer " <> sign(%{"sub" => @uid, "managed_session" => true})}
    ]

    conn = request(:get, "/api/chat/bootstrap", headers)
    assert conn.status == 403

    json = body_json(conn)
    assert json["error"]["code"] == "SESSION_NOT_ALLOWED"
  end
end
