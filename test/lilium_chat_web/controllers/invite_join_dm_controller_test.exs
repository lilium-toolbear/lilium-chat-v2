defmodule LiliumChatWeb.InviteJoinDmControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the issue #13 routes:

  * `POST /api/chat/channels/{channel_id}/invites` (§5.8)
  * `POST /api/chat/invites/{invite_code}/accept` (§5.9)
  * `POST /api/chat/channels/{channel_id}/join` (§5.7)
  * `POST /api/chat/dms` (§5.2c)

  Runs real conns through the entire endpoint pipeline (CORS → RequestId →
  router → Plug.Parsers → AuthPlug → controller → writer) and asserts the
  wire envelope, HTTP status, Idempotency-Key handling, auth, content-type,
  the `invite_url` assembly, and the v2 `ROUTE_INDEX_PENDING` routing split.
  Domain behavior is covered in `LiliumChat.InviteCommandsTest`,
  `LiliumChat.ChannelJoinTest`, and `LiliumChat.DmsTest`.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.InviteFixtures
  import LiliumChat.TestJWT
  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Repo

  @origin "https://lilium.kuma.homes"
  @viewer "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"
  @base "https://lilium.kuma.homes"

  # ------------------------------------------------------------- helpers

  defp request(method, path, headers, body) do
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

  defp auth_headers(claims \\ %{}),
    do: [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @viewer))}]

  defp other_headers(claims \\ %{}),
    do: [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @other))}]

  defp key_headers(claims, key, as \\ @viewer) do
    headers =
      if as == @viewer do
        auth_headers(claims)
      else
        other_headers(claims)
      end

    headers ++ [{"idempotency-key", key}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  defp seed_owned_channel(visibility \\ "public_listed") do
    cid = "ch-h13-" <> Ecto.UUID.generate()
    seed_channel(cid, visibility: visibility, created_by: @viewer)
    seed_membership(cid, @viewer, "owner")
    seed_profile(@viewer, "The Viewer", nil)
    seed_profile(@other, "The Other", nil)
    cid
  end

  # ------------------------------------------------- POST /channels/{id}/invites

  test "POST /channels/{id}/invites → 200 {invite_code, expires_at, max_uses, invite_url}" do
    cid = seed_owned_channel()

    conn =
      request(:post, "/api/chat/channels/#{cid}/invites", key_headers(%{}, "k-ic-1"), %{})

    assert conn.status == 200
    json = body_json(conn)

    code = personal_code(cid, @viewer)
    assert json["invite_code"] == code
    assert is_binary(json["expires_at"])
    assert json["max_uses"] == nil
    assert json["invite_url"] == "#{@base}/chat/invites/#{code}"
  end

  test "POST /channels/{id}/invites without Idempotency-Key → 422" do
    cid = seed_owned_channel()
    conn = request(:post, "/api/chat/channels/#{cid}/invites", auth_headers(), %{})
    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  # ------------------------------------------------ POST /invites/{code}/accept

  test "POST /invites/{code}/accept → 200 {channel, membership}" do
    cid = seed_owned_channel()
    code = personal_code(cid, @viewer)
    seed_invite(code, cid, created_by: @viewer)

    conn =
      request(
        :post,
        "/api/chat/invites/#{code}/accept",
        key_headers(%{}, "k-acc-1", @other),
        nil
      )

    assert conn.status == 200
    json = body_json(conn)
    assert json["channel"]["channel_id"] == cid
    assert json["channel"]["member_count"] == 2
    assert json["membership"]["role"] == "member"
    assert json["membership"]["status"] == "active"
    assert is_binary(json["membership"]["joined_at"])
  end

  test "POST /invites/{code}/accept unknown code → 404 INVITE_NOT_FOUND" do
    conn =
      request(
        :post,
        "/api/chat/invites/unknown-code-xyz/accept",
        key_headers(%{}, "k-acc-2"),
        nil
      )

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "INVITE_NOT_FOUND"
  end

  test "POST /invites/{code}/accept pending route → 409 ROUTE_INDEX_PENDING (retryable)" do
    Repo.query!(
      "INSERT INTO chat_v2.invites (invite_code, created_by, channel_id, expires_at, max_uses, " <>
        "used_count, revoked_at, created_at) " <>
        "VALUES ('code-h13-pending', $1, NULL, $2, NULL, 0, NULL, $2)",
      [@viewer, DateTime.utc_now() |> DateTime.add(7, :day)],
      type: true
    )

    conn =
      request(
        :post,
        "/api/chat/invites/code-h13-pending/accept",
        key_headers(%{}, "k-acc-3"),
        nil
      )

    assert conn.status == 409
    json = body_json(conn)["error"]
    assert json["code"] == "ROUTE_INDEX_PENDING"
    assert json["retryable"] == true
  end

  # -------------------------------------------------- POST /channels/{id}/join

  test "POST /channels/{id}/join → 200 {channel, membership}" do
    cid = seed_owned_channel("public_listed")

    conn =
      request(:post, "/api/chat/channels/#{cid}/join", key_headers(%{}, "k-join-1", @other), nil)

    assert conn.status == 200
    json = body_json(conn)
    assert json["channel"]["channel_id"] == cid
    assert json["channel"]["member_count"] == 2
    assert json["channel"]["role"] == "member"
    assert json["membership"]["role"] == "member"
    assert is_binary(json["membership"]["joined_at"])
  end

  test "POST /channels/{id}/join without Idempotency-Key → 422" do
    cid = seed_owned_channel()
    conn = request(:post, "/api/chat/channels/#{cid}/join", other_headers(), nil)
    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  # ------------------------------------------------------------ POST /dms

  test "POST /dms → 200 {channel, membership} (200, not 201)" do
    seed_profile(@viewer, "The Viewer", nil)
    seed_profile(@other, "The Other", nil)

    conn =
      request(:post, "/api/chat/dms", key_headers(%{}, "k-dm-1"), %{"recipient_user_id" => @other})

    assert conn.status == 200
    json = body_json(conn)
    assert json["channel"]["kind"] == "dm"
    assert json["channel"]["visibility"] == "private"
    assert json["channel"]["title"] == "The Other"
    assert json["channel"]["member_count"] == 2
    assert json["channel"]["role"] == "member"
    assert json["channel"]["unread_count"] == 0
    assert json["channel"]["dm_peer"]["user_id"] == @other
    assert json["membership"]["role"] == "member"
    assert is_binary(json["membership"]["joined_at"])
  end

  test "POST /dms without recipient → 422 INVALID_DM_TARGET" do
    seed_profile(@viewer, "The Viewer", nil)
    conn = request(:post, "/api/chat/dms", key_headers(%{}, "k-dm-2"), %{})
    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_DM_TARGET"
  end

  test "POST /dms without Idempotency-Key → 422" do
    seed_profile(@viewer, "The Viewer", nil)
    conn = request(:post, "/api/chat/dms", auth_headers(), %{"recipient_user_id" => @other})
    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  # -------------------------------------------------------------- auth

  test "all four routes require auth (401 UNAUTHORIZED without a token)" do
    cid = seed_owned_channel()
    code = personal_code(cid, @viewer)
    seed_invite(code, cid, created_by: @viewer)

    paths = [
      {:post, "/api/chat/channels/#{cid}/invites", %{}},
      {:post, "/api/chat/invites/#{code}/accept", nil},
      {:post, "/api/chat/channels/#{cid}/join", nil},
      {:post, "/api/chat/dms", %{"recipient_user_id" => @other}}
    ]

    for {method, path, body} <- paths do
      conn = request(method, path, [{"idempotency-key", "k-auth"}], body)
      assert conn.status == 401, "expected 401 for #{path}, got #{conn.status}"
      assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
    end
  end
end
