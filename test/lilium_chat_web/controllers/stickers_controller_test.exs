defmodule LiliumChatWeb.StickersControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the personal sticker library routes
  (contract §8.3, issues #7 / #15): `GET /stickers`, `POST /stickers`,
  `DELETE /stickers/:sticker_id`.

  Runs real conns through the ENTIRE endpoint pipeline (CORS → RequestId →
  router → AuthPlug → controller), so JWT auth, the error envelope, CORS and
  X-Request-Id are all exercised.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT
  import LiliumChatWeb.ReadFixtures

  @origin "https://lilium.kuma.homes"
  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @uid2 "7f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @ch "sticker-ch-0000-7000-8000-000000000001"

  setup do
    seed_channel(@ch, created_by: @uid)
    seed_membership(@ch, @uid, "member")
    seed_membership(@ch, @uid2, "member")
    :ok
  end

  defp request(method, path, headers, body) do
    conn =
      case body do
        nil ->
          Plug.Test.conn(method, path) |> apply_headers(headers)

        json ->
          Plug.Test.conn(method, path, Jason.encode!(json))
          |> apply_headers([{"content-type", "application/json"} | headers])
      end

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp auth_headers(user, extra) do
    extra ++ [{"authorization", "Bearer " <> sign(%{"sub" => user})}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  # ------------------------------------------------------------- save (POST)

  test "POST /stickers: 200 with the §8.3 PersonalSticker shape, X-Request-Id, replayable" do
    seed_attachment("att-web-1", owner_user_id: @uid)
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-1"}])
    body = %{"channel_id" => @ch, "attachment_id" => "att-web-1"}

    conn = request(:post, "/api/chat/stickers", headers, body)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]
    assert hd(get_resp_header(conn, "x-request-id")) =~ ~r/^req_/

    json = body_json(conn)
    sticker = json["sticker"]
    assert is_binary(sticker["sticker_id"])
    assert is_binary(sticker["created_at"])
    assert sticker["attachment"]["attachment_id"] == "att-web-1"
    assert sticker["attachment"]["url"] == "https://s3.example.com/att-web-1"
    assert sticker["attachment"]["mime_type"] == "image/png"
    assert sticker["attachment"]["size_bytes"] == 1024

    # Idempotent replay (same key + body) returns the identical response.
    conn2 = request(:post, "/api/chat/stickers", headers, body)
    assert body_json(conn2) == json
  end

  test "POST /stickers: no auth → 401 UNAUTHORIZED" do
    seed_attachment("att-web-2", owner_user_id: @uid)
    headers = [{"origin", @origin}, {"idempotency-key", "web-stk-2"}]

    conn =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => "att-web-2"
      })

    assert conn.status == 401
    assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
  end

  test "POST /stickers: missing Idempotency-Key → 422 INVALID_MESSAGE" do
    seed_attachment("att-web-3", owner_user_id: @uid)
    headers = auth_headers(@uid, [{"origin", @origin}])

    conn =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => "att-web-3"
      })

    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  test "POST /stickers: missing attachment_id → 422 INVALID_MESSAGE" do
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-4"}])
    conn = request(:post, "/api/chat/stickers", headers, %{"channel_id" => @ch})
    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  test "POST /stickers: same key + different body → 409 IDEMPOTENCY_CONFLICT" do
    seed_attachment("att-web-5a", owner_user_id: @uid)
    seed_attachment("att-web-5b", owner_user_id: @uid)
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-5"}])

    conn1 =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => "att-web-5a"
      })

    assert conn1.status == 200

    conn2 =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => "att-web-5b"
      })

    assert conn2.status == 409
    assert body_json(conn2)["error"]["code"] == "IDEMPOTENCY_CONFLICT"
  end

  test "POST /stickers: attachment not visible in the channel → 422 INVALID_STICKER_SOURCE" do
    seed_attachment("att-web-6", owner_user_id: @uid2)
    # no message links att-web-6 to @ch → channel-visible lookup misses
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-6"}])

    conn =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => "att-web-6"
      })

    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_STICKER_SOURCE"
  end

  test "POST /stickers: library limit → 409 STICKER_LIBRARY_LIMIT_EXCEEDED" do
    for n <- 1..200 do
      seed_personal_sticker("st-web-limit-#{n}", @uid, "att-web-limit-#{n}")
    end

    seed_attachment("att-web-7", owner_user_id: @uid)
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-7"}])

    conn =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => "att-web-7"
      })

    assert conn.status == 409
    assert body_json(conn)["error"]["code"] == "STICKER_LIBRARY_LIMIT_EXCEEDED"
  end

  test "POST /stickers: a member can save an attachment from a visible image message" do
    seed_attachment("att-web-8", owner_user_id: @uid2)
    msg = seed_message("sticker-ch-0001-7000-8000-000000000001", @ch, @uid2, nil, type: "image")
    seed_message_attachment(msg, "att-web-8")

    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-8"}])

    conn =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => "att-web-8"
      })

    assert conn.status == 200
    assert body_json(conn)["sticker"]["attachment"]["attachment_id"] == "att-web-8"
  end

  # ---------------------------------------------------------- delete (DELETE)

  test "DELETE /stickers/:sticker_id: 200 {sticker_id, deleted:true}, idempotent, and list reflects it" do
    sticker_id = save_via_endpoint(@uid, "att-del-web-1", "web-stk-d1")
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-d1-del"}])

    conn = request(:delete, "/api/chat/stickers/#{sticker_id}", headers, nil)
    assert conn.status == 200
    assert body_json(conn) == %{"sticker_id" => sticker_id, "deleted" => true}

    # repeat delete → identical idempotent result
    conn2 = request(:delete, "/api/chat/stickers/#{sticker_id}", headers, nil)
    assert body_json(conn2) == %{"sticker_id" => sticker_id, "deleted" => true}

    # the list no longer shows it
    list_conn =
      request(:get, "/api/chat/stickers", auth_headers(@uid, [{"origin", @origin}]), nil)

    assert body_json(list_conn)["items"] == []
  end

  test "DELETE /stickers/:sticker_id: missing Idempotency-Key → 422 INVALID_MESSAGE" do
    sticker_id = save_via_endpoint(@uid, "att-del-web-2", "web-stk-d2")
    headers = auth_headers(@uid, [{"origin", @origin}])
    conn = request(:delete, "/api/chat/stickers/#{sticker_id}", headers, nil)
    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  test "DELETE /stickers/:sticker_id: same key + different sticker_id → 409 IDEMPOTENCY_CONFLICT" do
    s1 = save_via_endpoint(@uid, "att-del-web-3a", "web-stk-d3a")
    s2 = save_via_endpoint(@uid, "att-del-web-3b", "web-stk-d3b")
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-d3"}])

    conn1 = request(:delete, "/api/chat/stickers/#{s1}", headers, nil)
    assert conn1.status == 200

    conn2 = request(:delete, "/api/chat/stickers/#{s2}", headers, nil)
    assert conn2.status == 409
    assert body_json(conn2)["error"]["code"] == "IDEMPOTENCY_CONFLICT"
  end

  test "DELETE /stickers/:sticker_id: another user's sticker → idempotent no-op (Worker parity)" do
    # Contract §8.3: sticker_id 跨用户不稳定 + 重复删除幂等; the old Worker's
    # per-DO storage makes a foreign sticker_id a plain no-op success.
    sticker_id = save_via_endpoint(@uid2, "att-del-web-4", "web-stk-d4")
    headers = auth_headers(@uid, [{"origin", @origin}, {"idempotency-key", "web-stk-d4-del"}])
    conn = request(:delete, "/api/chat/stickers/#{sticker_id}", headers, nil)
    assert conn.status == 200
    assert body_json(conn)["deleted"] == true
    assert body_json(conn)["sticker_id"] == sticker_id
  end

  test "DELETE /stickers/:sticker_id: no auth → 401 UNAUTHORIZED" do
    sticker_id = save_via_endpoint(@uid, "att-del-web-5", "web-stk-d5")
    headers = [{"origin", @origin}, {"idempotency-key", "web-stk-d5-del"}]
    conn = request(:delete, "/api/chat/stickers/#{sticker_id}", headers, nil)
    assert conn.status == 401
    assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
  end

  # ------------------------------------------------------------- round-trip

  test "save → list shows the item with the canonical attachment projection" do
    sticker_id = save_via_endpoint(@uid, "att-rt-1", "web-stk-rt1")

    list_conn =
      request(:get, "/api/chat/stickers", auth_headers(@uid, [{"origin", @origin}]), nil)

    assert list_conn.status == 200
    json = body_json(list_conn)
    assert length(json["items"]) == 1
    item = hd(json["items"])
    assert item["sticker_id"] == sticker_id
    assert item["attachment"]["attachment_id"] == "att-rt-1"
    assert item["attachment"]["url"] == "https://s3.example.com/att-rt-1"
  end

  # ---------------------------------------------------------------- helpers

  # POST /stickers via the endpoint as `user`; returns the sticker_id.
  defp save_via_endpoint(user, attachment_id, op_key) do
    seed_attachment(attachment_id, owner_user_id: user)
    headers = auth_headers(user, [{"origin", @origin}, {"idempotency-key", op_key}])

    conn =
      request(:post, "/api/chat/stickers", headers, %{
        "channel_id" => @ch,
        "attachment_id" => attachment_id
      })

    assert conn.status == 200
    body_json(conn)["sticker"]["sticker_id"]
  end
end
