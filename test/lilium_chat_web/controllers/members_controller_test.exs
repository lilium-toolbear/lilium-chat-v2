defmodule LiliumChatWeb.MembersControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the member-management routes (issue
  #12, contract §7.2 / §7.3 / §7.4 / §7.5):

  * `POST /api/chat/channels/{channel_id}/members`
  * `PATCH /api/chat/channels/{channel_id}/members/{user_id}`
  * `DELETE /api/chat/channels/{channel_id}/members/{user_id}`
  * `POST /api/chat/channels/{channel_id}/owner-transfer`

  Runs real conns through the entire endpoint pipeline (CORS → RequestId →
  router → Plug.Parsers → AuthPlug → controller → writer) and asserts the
  wire envelope, HTTP status, Idempotency-Key handling, auth, and
  content-type. Domain behavior (rows, events, hints) is covered in
  `LiliumChat.MemberCommandsTest`.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT
  import LiliumChatWeb.ReadFixtures

  @origin "https://lilium.kuma.homes"
  @viewer "11111111-2222-4333-8444-555555555555"
  @member "12222222-3333-4444-8555-666666666666"
  @target "13333333-4444-4555-8666-777777777777"

  # ------------------------------------------------------------- helpers

  defp request(method, path, headers, body \\ nil) do
    raw = if body == nil, do: nil, else: Jason.encode!(body)

    headers = [{"origin", @origin} | headers]

    conn =
      Plug.Test.conn(method, path, raw)
      |> apply_headers(headers)
      |> put_body_header(raw)

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp put_body_header(conn, nil), do: conn

  defp put_body_header(conn, body) do
    Plug.Conn.put_req_header(conn, "content-type", "application/json")
    |> Plug.Conn.put_req_header("content-length", Integer.to_string(byte_size(body)))
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp auth_headers(claims \\ %{}) do
    [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @viewer))}]
  end

  defp key_headers(claims, key) do
    auth_headers(claims) ++ [{"idempotency-key", key}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  defp seed_managed_channel() do
    cid = "ch-memb-" <> Ecto.UUID.generate()

    seed_channel(cid, title: "Managed", created_by: @viewer)
    seed_membership(cid, @viewer, "owner")
    seed_membership(cid, @member, "admin")
    seed_membership(cid, @target, "member")
    seed_profile(@viewer, "The Viewer", nil)
    seed_profile(@member, "The Member", nil)
    seed_profile(@target, "The Target", nil)

    cid
  end

  # ------------------------------------------------------------- headers

  test "write routes without Idempotency-Key → 422 INVALID_MESSAGE" do
    cid = seed_managed_channel()

    paths = [
      {:post, "/api/chat/channels/#{cid}/members", %{"user_id" => @target, "role" => "member"}},
      {:patch, "/api/chat/channels/#{cid}/members/#{@member}", %{"role" => "member"}},
      {:delete, "/api/chat/channels/#{cid}/members/#{@member}", nil},
      {:post, "/api/chat/channels/#{cid}/owner-transfer",
       %{"target_user_id" => @target, "previous_owner_role" => "admin"}}
    ]

    for {method, path, body} <- paths do
      conn = request(method, path, auth_headers(), body)
      assert conn.status == 422, "expected 422 for #{path}, got #{conn.status}"
      assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
    end
  end

  test "write routes require auth (401 UNAUTHORIZED without a token)" do
    cid = seed_managed_channel()

    paths = [
      {:post, "/api/chat/channels/#{cid}/members", %{"user_id" => @target, "role" => "member"}},
      {:patch, "/api/chat/channels/#{cid}/members/#{@member}", %{"role" => "member"}},
      {:delete, "/api/chat/channels/#{cid}/members/#{@member}", nil},
      {:post, "/api/chat/channels/#{cid}/owner-transfer",
       %{"target_user_id" => @target, "previous_owner_role" => "admin"}}
    ]

    for {method, path, body} <- paths do
      headers = [{"idempotency-key", "k-#{method}"}]
      conn = request(method, path, headers, body)
      assert conn.status == 401, "expected 401 for #{path}, got #{conn.status}"
      assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
    end
  end

  # ------------------------------------------------------------ add (§7.2)

  test "POST /members → 200 member projection" do
    cid = seed_managed_channel()

    # @member is already an active admin: re-adding with a DIFFERENT role is
    # 422 (that's PATCH's job), not a silent role change.
    conn =
      request(
        :post,
        "/api/chat/channels/#{cid}/members",
        key_headers(%{}, "http-m1"),
        %{"user_id" => @member, "role" => "member"}
      )

    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"

    stranger = "14444444-5555-4666-8777-888888888888"
    seed_profile(stranger, "Stranger", nil)

    conn =
      request(
        :post,
        "/api/chat/channels/#{cid}/members",
        key_headers(%{}, "http-m2"),
        %{"user_id" => stranger, "role" => "member"}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]
    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_/

    json = body_json(conn)
    assert json["member"]["channel_id"] == cid
    assert json["member"]["user_id"] == stranger
    assert json["member"]["role"] == "member"
    assert is_binary(json["member"]["joined_at"])
  end

  test "POST /members idempotent replay: same key + body → identical response" do
    cid = seed_managed_channel()
    stranger = "15555555-6666-4777-8888-999999999999"
    seed_profile(stranger, "Stranger", nil)

    headers = fn -> key_headers(%{}, "http-replay") end
    body = %{"user_id" => stranger, "role" => "member"}

    first = request(:post, "/api/chat/channels/#{cid}/members", headers.(), body)
    second = request(:post, "/api/chat/channels/#{cid}/members", headers.(), body)

    assert first.status == 200
    assert second.status == 200
    assert body_json(first) == body_json(second)
  end

  test "POST /members same key different body → 409 IDEMPOTENCY_CONFLICT" do
    cid = seed_managed_channel()

    s1 = "16666666-7777-4888-8999-000000000001"
    s2 = "16666666-7777-4888-8999-000000000002"
    seed_profile(s1, "S1", nil)
    seed_profile(s2, "S2", nil)

    headers = fn -> key_headers(%{}, "http-conflict") end

    first = request(:post, "/api/chat/channels/#{cid}/members", headers.(), %{"user_id" => s1})
    assert first.status == 200

    conflict = request(:post, "/api/chat/channels/#{cid}/members", headers.(), %{"user_id" => s2})
    assert conflict.status == 409
    assert body_json(conflict)["error"]["code"] == "IDEMPOTENCY_CONFLICT"
  end

  # -------------------------------------------------------- role (§7.3)

  test "PATCH /members/{user_id} → 200 updated member projection" do
    cid = seed_managed_channel()

    conn =
      request(
        :patch,
        "/api/chat/channels/#{cid}/members/#{@target}",
        key_headers(%{}, "http-r1"),
        %{"role" => "admin"}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    json = body_json(conn)
    assert json["member"]["channel_id"] == cid
    assert json["member"]["user_id"] == @target
    assert json["member"]["role"] == "admin"
  end

  test "PATCH /members/{user_id} → 403 FORBIDDEN for a non-owner caller" do
    cid = seed_managed_channel()

    # @member (an admin) is not the owner
    conn =
      request(
        :patch,
        "/api/chat/channels/#{cid}/members/#{@target}",
        key_headers(%{"sub" => @member}, "http-r2"),
        %{"role" => "member"}
      )

    assert conn.status == 403
    assert body_json(conn)["error"]["code"] == "FORBIDDEN"
  end

  test "PATCH /members/{user_id} → 404 CHANNEL_NOT_FOUND for a missing channel" do
    missing = "ch-memb-none-" <> Ecto.UUID.generate()

    conn =
      request(
        :patch,
        "/api/chat/channels/#{missing}/members/#{@target}",
        key_headers(%{}, "http-r3"),
        %{"role" => "admin"}
      )

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "CHANNEL_NOT_FOUND"
  end

  # ---------------------------------------------------- remove (§7.4)

  test "DELETE /members/{user_id} → 200 {channel_id, user_id, removed}" do
    cid = seed_managed_channel()

    conn =
      request(
        :delete,
        "/api/chat/channels/#{cid}/members/#{@target}",
        key_headers(%{}, "http-d1")
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    json = body_json(conn)
    assert json == %{"channel_id" => cid, "user_id" => @target, "removed" => true}
  end

  test "DELETE /members/{user_id} → 409 CHANNEL_DISSOLVED removing another on a dissolved channel" do
    cid = seed_managed_channel()

    dissolve =
      request(
        :post,
        "/api/chat/channels/#{cid}/dissolve",
        key_headers(%{}, "http-d2-dissolve")
      )

    assert dissolve.status == 200

    # a non-self removal on a dissolved channel is 409 (self-leave stays allowed)
    conn =
      request(
        :delete,
        "/api/chat/channels/#{cid}/members/#{@member}",
        key_headers(%{}, "http-d2")
      )

    assert conn.status == 409
    assert body_json(conn)["error"]["code"] == "CHANNEL_DISSOLVED"
  end

  # ---------------------------------------------------- transfer (§7.5)

  test "POST /owner-transfer → 200 {channel_id, previous_owner, new_owner}" do
    cid = seed_managed_channel()

    conn =
      request(
        :post,
        "/api/chat/channels/#{cid}/owner-transfer",
        key_headers(%{}, "http-t1"),
        %{"target_user_id" => @member, "previous_owner_role" => "admin"}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    json = body_json(conn)
    assert json["channel_id"] == cid
    assert json["previous_owner"] == %{"user_id" => @viewer, "role" => "admin"}
    assert json["new_owner"] == %{"user_id" => @member, "role" => "owner"}
  end

  test "POST /owner-transfer → 422 INVALID_MEMBER_ROLE for the current owner as target" do
    cid = seed_managed_channel()

    conn =
      request(
        :post,
        "/api/chat/channels/#{cid}/owner-transfer",
        key_headers(%{}, "http-t2"),
        %{"target_user_id" => @viewer, "previous_owner_role" => "admin"}
      )

    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MEMBER_ROLE"
  end

  test "error envelope shape (contract §2.6) on the new routes" do
    missing = "ch-memb-none2-" <> Ecto.UUID.generate()

    conn =
      request(
        :post,
        "/api/chat/channels/#{missing}/owner-transfer",
        key_headers(%{}, "http-t3"),
        %{"target_user_id" => @member, "previous_owner_role" => "admin"}
      )

    assert conn.status == 404

    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_/

    json = body_json(conn)
    assert json["error"]["code"] == "CHANNEL_NOT_FOUND"
    assert json["error"]["retryable"] == false
    assert json["request_id"] == id
  end
end
