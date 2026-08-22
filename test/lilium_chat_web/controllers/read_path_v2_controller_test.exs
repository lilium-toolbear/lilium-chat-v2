defmodule LiliumChatWeb.ReadPathV2ControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the issue #7 read routes:
  members list/detail (§7.1/§7.1b), channel directory (§5.6), invite preview
  (§5.10), and personal stickers (§8.3). Runs real conns through the entire
  endpoint pipeline (CORS → RequestId → router → AuthPlug → controller) and
  asserts the wire envelope, auth, error codes, X-Request-Id, and the
  read-only (A12) property for each route.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT
  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Observability.ReadPath

  @origin "https://lilium.kuma.homes"
  @viewer "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "22222222-2222-7222-8222-222222222222"
  @stranger "99999999-9999-7999-8999-999999999999"

  # ------------------------------------------------------------- helpers

  defp request(method, path, headers) do
    conn = Plug.Test.conn(method, path) |> apply_headers(headers)
    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp auth_headers(claims \\ %{}, opts \\ []) do
    [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @viewer), opts)}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  # ------------------------------------------------------------- auth (401)

  test "each issue #7 read route requires auth (401 UNAUTHORIZED without a token)" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"

    paths = [
      "/api/chat/channels/directory",
      "/api/chat/channels/#{ch}/members",
      "/api/chat/channels/#{ch}/members/#{@other}",
      "/api/chat/invites/some-code",
      "/api/chat/stickers"
    ]

    for path <- paths do
      conn = request(:get, path, [{"origin", @origin}])
      assert conn.status == 401, "expected 401 for #{path}, got #{conn.status}"
      assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
    end
  end

  # ------------------------------------------------------ channel directory

  test "GET /channels/directory returns the §5.6 envelope and item shape" do
    listed =
      "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
      |> seed_channel(title: "Game Night", visibility: "public_listed", created_by: @other)

    seed_channel("bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb",
      title: "Private One",
      visibility: "private",
      created_by: @other
    )

    conn = request(:get, "/api/chat/channels/directory", [{"origin", @origin} | auth_headers()])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]
    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_/

    json = body_json(conn)
    assert is_list(json["items"])
    assert json["next_cursor"] == nil

    [item] = json["items"]
    assert item["channel_id"] == listed
    assert item["kind"] == "channel"
    assert item["visibility"] == "public_listed"
    assert item["title"] == "Game Night"
    assert item["status"] == "active"
    assert item["unread_count"] == 0
    assert item["last_message_preview"] == nil
    assert item["role"] == nil
    assert item["last_read_event_id"] == nil
    assert Map.has_key?(item, "member_count")
    assert Map.has_key?(item, "avatar_url")
    assert Map.has_key?(item, "last_message_at")
  end

  test "GET /channels/directory filters by q and pages with the keyset cursor" do
    ch_a =
      seed_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa",
        title: "Alpha",
        visibility: "public_listed"
      )

    seed_channel("bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb",
      title: "Bravo",
      visibility: "public_listed"
    )

    seed_channel("cccccccc-0000-7000-8000-cccccccccccc",
      title: "Charlie",
      visibility: "public_listed"
    )

    # q filter (case-insensitive substring).
    conn =
      request(:get, "/api/chat/channels/directory?q=alp", [{"origin", @origin} | auth_headers()])

    json = body_json(conn)
    assert Enum.map(json["items"], & &1["channel_id"]) == [ch_a]

    # Paging: limit=2 → 2 + cursor, then the remainder.
    page1 =
      request(:get, "/api/chat/channels/directory?limit=2", [{"origin", @origin} | auth_headers()])

    page1 = body_json(page1)
    assert length(page1["items"]) == 2
    assert is_binary(page1["next_cursor"])

    page2_url =
      "/api/chat/channels/directory?limit=2&cursor=" <> URI.encode_www_form(page1["next_cursor"])

    page2 = request(:get, page2_url, [{"origin", @origin} | auth_headers()]) |> body_json()

    assert length(page2["items"]) == 1
    assert page2["next_cursor"] == nil

    all = page1["items"] ++ page2["items"]
    assert length(Enum.uniq(Enum.map(all, & &1["channel_id"]))) == 3
  end

  test "GET /channels/directory is read-only (A12)" do
    seed_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa",
      title: "Alpha",
      visibility: "public_listed"
    )

    seed_membership("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa", @viewer, "member")

    ReadPath.assert_read_only!(
      fn ->
        request(:get, "/api/chat/channels/directory", [{"origin", @origin} | auth_headers()])
      end,
      "GET /api/chat/channels/directory"
    )
  end

  # ------------------------------------------------------------- members

  test "GET /channels/{id}/members returns the §7.1 list with resolved profiles" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Members", created_by: @viewer)
    seed_membership(ch, @viewer, "admin")

    seed_membership(ch, @other, "member",
      joined_at: DateTime.utc_now() |> DateTime.add(1, :second)
    )

    seed_profile(@other, "Alice O'Hara", nil)

    conn =
      request(:get, "/api/chat/channels/#{ch}/members", [{"origin", @origin} | auth_headers()])

    assert conn.status == 200
    json = body_json(conn)
    assert json["next_cursor"] == nil
    assert length(json["items"]) == 2

    [first, second] = json["items"]
    # The admin (owner rank 0/1) sorts before members; the viewer is included.
    assert first["role"] == "admin"
    assert second["user"]["user_id"] == @other
    assert second["user"]["display_name"] == "Alice O'Hara"
    assert Map.has_key?(second, "joined_at")
  end

  test "GET /channels/{id}/members?query= filters by display name prefix" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Members", created_by: @viewer)
    seed_membership(ch, @viewer, "admin")

    seed_membership(ch, @other, "member",
      joined_at: DateTime.utc_now() |> DateTime.add(1, :second)
    )

    seed_profile(@other, "Alice O'Hara", nil)

    conn =
      request(:get, "/api/chat/channels/#{ch}/members?query=alice", [
        {"origin", @origin} | auth_headers()
      ])

    assert conn.status == 200
    json = body_json(conn)
    assert json["next_cursor"] == nil
    assert length(json["items"]) == 1
    assert hd(json["items"])["user"]["display_name"] == "Alice O'Hara"
  end

  test "GET /channels/{id}/members → 404 CHANNEL_NOT_FOUND and 403 FORBIDDEN" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Members", created_by: @viewer)
    seed_membership(ch, @viewer, "admin")

    # Missing channel.
    conn =
      request(:get, "/api/chat/channels/ffffffff-0000-7000-8000-ffffffffffff/members", [
        {"origin", @origin} | auth_headers()
      ])

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "CHANNEL_NOT_FOUND"

    # A non-member viewer is forbidden.
    headers = auth_headers(%{"sub" => @stranger})
    conn = request(:get, "/api/chat/channels/#{ch}/members", [{"origin", @origin} | headers])
    assert conn.status == 403
    assert body_json(conn)["error"]["code"] == "FORBIDDEN"
  end

  test "GET /channels/{id}/members is read-only (A12)" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Members", created_by: @viewer)
    seed_membership(ch, @viewer, "admin")

    seed_membership(ch, @other, "member",
      joined_at: DateTime.utc_now() |> DateTime.add(1, :second)
    )

    seed_profile(@other, "Alice O'Hara", nil)

    ReadPath.assert_read_only!(
      fn ->
        request(:get, "/api/chat/channels/#{ch}/members", [{"origin", @origin} | auth_headers()])
      end,
      "GET /api/chat/channels/{id}/members"
    )
  end

  test "GET /channels/{id}/members/{user_id} returns the exact member record" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Members", created_by: @viewer)
    seed_membership(ch, @viewer, "admin")
    joined_at = DateTime.utc_now() |> DateTime.add(1, :second)
    seed_membership(ch, @other, "member", joined_at: joined_at)
    seed_profile(@other, "Alice O'Hara", "https://cdn.example.com/alice.png")

    conn =
      request(:get, "/api/chat/channels/#{ch}/members/#{@other}", [
        {"origin", @origin} | auth_headers()
      ])

    assert conn.status == 200
    json = body_json(conn)

    assert json["user"] == %{
             "user_id" => @other,
             "display_name" => "Alice O'Hara",
             "avatar_url" => "https://cdn.example.com/alice.png"
           }

    assert json["role"] == "member"
    assert json["status"] == "active"
    assert json["joined_at"] != nil
  end

  test "GET /channels/{id}/members/{user_id} → 404 MEMBER_NOT_FOUND" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Members", created_by: @viewer)
    seed_membership(ch, @viewer, "admin")

    conn =
      request(:get, "/api/chat/channels/#{ch}/members/#{@stranger}", [
        {"origin", @origin} | auth_headers()
      ])

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "MEMBER_NOT_FOUND"
  end

  # --------------------------------------------------------------- invites

  test "GET /invites/{code} returns the §5.10 preview without join side effects" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Invited", created_by: @other, member_count: 1)
    seed_membership(ch, @other, "owner")
    seed_profile(@other, "Alice O'Hara", nil)
    seed_invite("inv_abc", ch, created_by: @other, max_uses: 5)

    conn = request(:get, "/api/chat/invites/inv_abc", [{"origin", @origin} | auth_headers()])

    assert conn.status == 200
    json = body_json(conn)

    assert json["invite"]["invite_code"] == "inv_abc"
    assert json["invite"]["max_uses"] == 5
    assert json["channel"]["channel_id"] == ch
    assert json["channel"]["title"] == "Invited"
    assert json["inviter"]["user_id"] == @other
    assert json["inviter"]["display_name"] == "Alice O'Hara"
    assert is_list(json["sample_members"])
    assert length(json["sample_members"]) <= 3
    # The viewer has not joined.
    assert json["my_membership"] == %{"status" => "not_joined", "channel_id" => nil}
  end

  test "GET /invites/{code} is strictly read-only: zero PG writes (no join side effects)" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Invited", created_by: @other)
    seed_membership(ch, @other, "owner")
    seed_invite("inv_ro", ch, created_by: @other)

    ReadPath.assert_read_only!(
      fn ->
        request(:get, "/api/chat/invites/inv_ro", [{"origin", @origin} | auth_headers()])
      end,
      "GET /api/chat/invites/{code}"
    )
  end

  test "GET /invites/{code} → 404 INVITE_NOT_FOUND (missing / expired / revoked / channel missing)" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Invited", created_by: @other)
    seed_invite("inv_revoked", ch, created_by: @other, revoked_at: DateTime.utc_now())

    # Expired well in the past (a 1s margin flaked under the full suite).
    seed_invite("inv_expired", ch,
      created_by: @other,
      expires_at: DateTime.utc_now() |> DateTime.add(-1, :day)
    )

    seed_invite("inv_orphan", "99999999-0000-7000-8000-999999999999", created_by: @other)

    for code <- ["inv_missing", "inv_revoked", "inv_expired", "inv_orphan"] do
      conn = request(:get, "/api/chat/invites/#{code}", [{"origin", @origin} | auth_headers()])
      assert conn.status == 404, "expected 404 for #{code}, got #{conn.status}"
      assert body_json(conn)["error"]["code"] == "INVITE_NOT_FOUND"
    end
  end

  # --------------------------------------------------------------- stickers

  test "GET /stickers returns the §8.3 list newest-first with the attachment projection" do
    ts30 = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.truncate(:microsecond)
    ts20 = DateTime.utc_now() |> DateTime.add(20, :second) |> DateTime.truncate(:microsecond)

    seed_personal_sticker("st_a", @viewer, "att_a", created_at: ts30)
    seed_personal_sticker("st_b", @viewer, "att_b", created_at: ts20)
    seed_personal_sticker("st_other", @other, "att_c", created_at: DateTime.utc_now())

    conn = request(:get, "/api/chat/stickers", [{"origin", @origin} | auth_headers()])

    assert conn.status == 200
    json = body_json(conn)
    assert Enum.map(json["items"], & &1["sticker_id"]) == ["st_a", "st_b"]
    assert json["next_cursor"] == NaiveDateTime.to_iso8601(ts20)

    [item, _] = json["items"]
    assert item["attachment"]["attachment_id"] == "att_a"
    assert item["attachment"]["url"] == "https://s3.example.com/att_a"
    assert item["attachment"]["mime_type"] == "image/png"
    assert item["attachment"]["width"] == 512
    assert item["attachment"]["height"] == 512
    assert item["attachment"]["size_bytes"] == 12345
    assert item["created_at"] != nil
  end

  test "GET /stickers?cursor= pages newest-first" do
    for n <- 1..4 do
      seed_personal_sticker("st_#{n}", @viewer, "att_#{n}",
        created_at: DateTime.utc_now() |> DateTime.add(n, :second)
      )
    end

    page1 = request(:get, "/api/chat/stickers?limit=2", [{"origin", @origin} | auth_headers()])
    page1 = body_json(page1)
    assert length(page1["items"]) == 2
    assert hd(page1["items"])["sticker_id"] == "st_4"

    page2_url = "/api/chat/stickers?limit=2&cursor=" <> URI.encode_www_form(page1["next_cursor"])
    page2 = request(:get, page2_url, [{"origin", @origin} | auth_headers()]) |> body_json()

    assert length(page2["items"]) == 2
    assert hd(page2["items"])["sticker_id"] == "st_2"
  end

  test "GET /stickers is read-only (A12)" do
    seed_personal_sticker("st_ro", @viewer, "att_ro", created_at: DateTime.utc_now())

    ReadPath.assert_read_only!(
      fn ->
        request(:get, "/api/chat/stickers", [{"origin", @origin} | auth_headers()])
      end,
      "GET /api/chat/stickers"
    )
  end
end
