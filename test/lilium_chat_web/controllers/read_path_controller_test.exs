defmodule LiliumChatWeb.ReadPathControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the read-path routes (issue #6):
  channels list/detail, messages, message context, channel events, and global
  events. Runs real conns through the entire endpoint pipeline (CORS →
  RequestId → router → AuthPlug → controller) and asserts the wire envelope,
  auth, error codes, X-Request-Id, and content-type.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT
  import LiliumChatWeb.ReadFixtures

  @origin "https://lilium.kuma.homes"
  @viewer "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "22222222-2222-7222-8222-222222222222"

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

  defp seed_basic_channel() do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Alpha", created_by: @viewer)
    seed_membership(ch, @viewer, "admin")
    seed_membership(ch, @other, "member")
    seed_profile(@viewer, "The Viewer", nil)
    seed_profile(@other, "Alice O'Hara", nil)

    message_id =
      seed_message("aaaaaaaa-0001-7000-8000-000000000001", ch, @other, "first message",
        event_id: eid(1),
        created_at: DateTime.utc_now() |> DateTime.add(1, :second)
      )

    {ch, message_id}
  end

  # ------------------------------------------------------------ auth (401)

  test "each read route requires auth (401 UNAUTHORIZED without a token)" do
    {ch, mid} = seed_basic_channel()

    paths = [
      "/api/chat/channels",
      "/api/chat/channels/#{ch}",
      "/api/chat/channels/#{ch}/messages",
      "/api/chat/channels/#{ch}/messages/#{mid}/context",
      "/api/chat/channels/#{ch}/events",
      "/api/chat/events"
    ]

    for path <- paths do
      conn = request(:get, path, [{"origin", @origin}])
      assert conn.status == 401, "expected 401 for #{path}, got #{conn.status}"
      assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
    end
  end

  # ---------------------------------------------------------- channels list

  test "GET /channels returns the list envelope with the ChannelSummary rows" do
    {ch, _} = seed_basic_channel()
    conn = request(:get, "/api/chat/channels", [{"origin", @origin} | auth_headers()])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]
    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_/

    json = body_json(conn)
    assert is_list(json["items"])
    assert json["next_cursor"] == nil

    [channel] = json["items"]
    assert channel["channel_id"] == ch
    assert channel["title"] == "Alpha"
    assert channel["role"] == "admin"
    assert channel["last_message_preview"] == "Alice O'Hara: first message"
  end

  # ---------------------------------------------------------- channels detail

  test "GET /channels/{id} returns channel + channel_pins" do
    {ch, mid} = seed_basic_channel()
    conn = request(:get, "/api/chat/channels/#{ch}", [{"origin", @origin} | auth_headers()])

    assert conn.status == 200
    json = body_json(conn)
    assert json["channel"]["channel_id"] == ch
    assert json["channel"]["title"] == "Alpha"
    assert is_list(json["channel_pins"])
    # Contract §5.2 ChannelDetail has no dm_peer field — the key is only
    # present for kind="dm" (issue #27).
    refute Map.has_key?(json["channel"], "dm_peer")
    _ = mid
  end

  test "GET /channels/{id} → 404 CHANNEL_NOT_FOUND for a missing channel" do
    conn =
      request(
        :get,
        "/api/chat/channels/ffffffff-0000-7000-8000-ffffffffffff",
        [{"origin", @origin} | auth_headers()]
      )

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "CHANNEL_NOT_FOUND"
  end

  test "GET /channels/{id} → 403 FORBIDDEN for a private channel without membership" do
    ch = "bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb"
    seed_channel(ch, title: "Secret", visibility: "private", created_by: @other)
    # viewer is not a member

    conn = request(:get, "/api/chat/channels/#{ch}", [{"origin", @origin} | auth_headers()])
    assert conn.status == 403
    assert body_json(conn)["error"]["code"] == "FORBIDDEN"
    # Contract §2.6 error-envelope example wording.
    assert body_json(conn)["error"]["message"] == "not a channel member"
  end

  # ---------------------------------------------------------- messages page

  test "GET /channels/{id}/messages returns EventFrame items + next_cursor" do
    {ch, _} = seed_basic_channel()

    conn =
      request(:get, "/api/chat/channels/#{ch}/messages", [{"origin", @origin} | auth_headers()])

    assert conn.status == 200
    json = body_json(conn)
    assert is_list(json["items"])
    assert json["next_cursor"] == nil

    [frame | _] = json["items"]
    assert frame["frame_type"] == "event"
    assert frame["api_version"] == "lilium.chat.v1"
    assert frame["type"] == "message.created"
    assert frame["payload"]["message"]["text"] == "first message"
  end

  # ---------------------------------------------------------- message context

  test "GET .../messages/{id}/context returns anchor + window" do
    {ch, mid} = seed_basic_channel()

    conn =
      request(
        :get,
        "/api/chat/channels/#{ch}/messages/#{mid}/context",
        [{"origin", @origin} | auth_headers()]
      )

    assert conn.status == 200
    json = body_json(conn)
    assert json["anchor_message_id"] == mid
    assert is_list(json["items"])
    assert length(json["items"]) >= 1
  end

  test "GET .../messages/{id}/context → 404 MESSAGE_NOT_FOUND for a missing message" do
    {ch, _} = seed_basic_channel()
    missing = "eeeeeeee-9999-7999-8999-999999999999"

    conn =
      request(
        :get,
        "/api/chat/channels/#{ch}/messages/#{missing}/context",
        [{"origin", @origin} | auth_headers()]
      )

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "MESSAGE_NOT_FOUND"
  end

  # ---------------------------------------------------------- channel events

  test "GET /channels/{id}/events returns events + latest_event_id + next_cursor" do
    {ch, _} = seed_basic_channel()

    conn =
      request(
        :get,
        "/api/chat/channels/#{ch}/events",
        [{"origin", @origin} | auth_headers()]
      )

    assert conn.status == 200
    json = body_json(conn)
    assert is_list(json["events"])
    assert json["latest_event_id"] != nil
    assert json["next_cursor"] == nil
  end

  # ---------------------------------------------------------- global events

  test "GET /events with ?channel_id=&after_event_id= returns the merged envelope" do
    {ch, _} = seed_basic_channel()

    conn =
      request(
        :get,
        "/api/chat/events?channel_id=#{ch}&after_event_id=",
        [{"origin", @origin} | auth_headers()]
      )

    assert conn.status == 200
    json = body_json(conn)
    assert is_list(json["items"])
    assert json["next_cursor"] == nil
    assert is_map(json["last_event_id_per_channel"])
    assert json["last_event_id_per_channel"][ch] != nil
  end

  test "GET /events with ?cursors= decodes the per-channel cursor map" do
    {ch, _} = seed_basic_channel()
    cursors = cursors_param(%{ch => ""})

    conn =
      request(
        :get,
        "/api/chat/events?cursors=#{cursors}",
        [{"origin", @origin} | auth_headers()]
      )

    assert conn.status == 200
    json = body_json(conn)
    assert is_list(json["items"])
    assert Map.has_key?(json["last_event_id_per_channel"], ch)
  end
end
