defmodule LiliumChatWeb.ChannelLifecycleControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the channel lifecycle routes (issue #11,
  contract §5.2b / §5.3 / §5.4): `POST /channels`,
  `PATCH /channels/{channel_id}`, `POST /channels/{channel_id}/dissolve`.

  Runs real conns through the entire endpoint pipeline (CORS → RequestId →
  router → Plug.Parsers → AuthPlug → controller → writer) and asserts the
  wire envelope, HTTP status, Idempotency-Key handling, auth, and
  content-type. Domain behavior (rows, events, hints) is covered in
  `LiliumChat.ChannelLifecycleTest`.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT
  import LiliumChatWeb.ReadFixtures

  @origin "https://lilium.kuma.homes"
  @viewer "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"

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

  defp seed_owned_channel(title \\ "Ops") do
    cid = "ch-http-" <> Ecto.UUID.generate()
    seed_channel(cid, title: title, created_by: @viewer)
    seed_membership(cid, @viewer, "owner")
    seed_profile(@viewer, "The Viewer", nil)
    cid
  end

  # ------------------------------------------------------------- headers

  test "POST /channels without Idempotency-Key → 422 INVALID_MESSAGE" do
    conn =
      request(
        :post,
        "/api/chat/channels",
        auth_headers(),
        %{"title" => "No Key"}
      )

    assert conn.status == 422
    assert get_resp_header(conn, "content-type") == ["application/json"]
    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_/

    json = body_json(conn)
    assert json["error"]["code"] == "INVALID_MESSAGE"
    assert json["error"]["retryable"] == false
    assert json["request_id"] == id
  end

  test "PATCH /channels/{id} without Idempotency-Key → 422 INVALID_MESSAGE" do
    cid = seed_owned_channel()

    conn =
      request(:patch, "/api/chat/channels/#{cid}", auth_headers(), %{"title" => "x"})

    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  test "POST /channels/{id}/dissolve without Idempotency-Key → 422 INVALID_MESSAGE" do
    cid = seed_owned_channel()

    conn = request(:post, "/api/chat/channels/#{cid}/dissolve", auth_headers())

    assert conn.status == 422
    assert body_json(conn)["error"]["code"] == "INVALID_MESSAGE"
  end

  test "write routes require auth (401 UNAUTHORIZED without a token)" do
    cid = seed_owned_channel()

    paths = [
      {:post, "/api/chat/channels", %{"title" => "x"}},
      {:patch, "/api/chat/channels/#{cid}", %{"title" => "x"}},
      {:post, "/api/chat/channels/#{cid}/dissolve", nil}
    ]

    for {method, path, body} <- paths do
      headers = [{"idempotency-key", "k-#{method}"}]
      conn = request(method, path, headers, body)
      assert conn.status == 401, "expected 401 for #{path}, got #{conn.status}"
      assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
    end
  end

  # --------------------------------------------------------------- create

  test "POST /channels → 201 create body (channel + membership)" do
    conn =
      request(
        :post,
        "/api/chat/channels",
        key_headers(%{}, "http-c1"),
        %{"title" => "  HTTP Ops  ", "topic" => "wire", "visibility" => "public_unlisted"}
      )

    assert conn.status == 201
    assert get_resp_header(conn, "content-type") == ["application/json"]
    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_/

    json = body_json(conn)
    ch = json["channel"]

    assert ch["kind"] == "channel"
    assert ch["visibility"] == "public_unlisted"
    assert ch["title"] == "HTTP Ops"
    assert ch["topic"] == "wire"
    assert ch["avatar_url"] == nil
    assert ch["member_count"] == 1
    assert ch["status"] == "active"
    assert is_binary(ch["channel_id"])
    assert is_binary(ch["created_at"])
    assert ch["created_at"] == ch["updated_at"]

    assert json["membership"] == %{"role" => "owner", "joined_at" => ch["created_at"]}
  end

  test "POST /channels idempotent replay: same key + body → identical response" do
    body = %{
      "title" => "Replay",
      "initial_members" => [%{"user_id" => @other, "role" => "member"}]
    }

    headers = fn -> key_headers(%{}, "http-replay") end

    first = request(:post, "/api/chat/channels", headers.(), body)
    second = request(:post, "/api/chat/channels", headers.(), body)

    assert first.status == 201
    assert second.status == 201
    assert body_json(first) == body_json(second)

    # exactly one channel row was created
    cid = body_json(first)["channel"]["channel_id"]

    rows =
      LiliumChat.Query.rows(
        LiliumChat.Repo.query("SELECT channel_id FROM chat_v2.channels WHERE channel_id = $1", [
          cid
        ])
      )

    assert length(rows) == 1
  end

  test "POST /channels same key different body → 409 IDEMPOTENCY_CONFLICT" do
    headers = fn -> key_headers(%{}, "http-conflict") end

    first = request(:post, "/api/chat/channels", headers.(), %{"title" => "A"})
    assert first.status == 201

    conflict = request(:post, "/api/chat/channels", headers.(), %{"title" => "B"})
    assert conflict.status == 409
    assert body_json(conflict)["error"]["code"] == "IDEMPOTENCY_CONFLICT"
  end

  # --------------------------------------------------------------- update

  test "PATCH /channels/{id} → 200 updated channel projection" do
    cid = seed_owned_channel("Before")

    conn =
      request(
        :patch,
        "/api/chat/channels/#{cid}",
        key_headers(%{}, "http-u1"),
        %{"title" => "After", "topic" => nil, "visibility" => "public_listed"}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    json = body_json(conn)
    ch = json["channel"]
    assert ch["channel_id"] == cid
    assert ch["title"] == "After"
    assert ch["topic"] == nil
    assert ch["visibility"] == "public_listed"
    assert ch["status"] == "active"
    assert is_binary(ch["updated_at"])
  end

  test "PATCH /channels/{id} → 404 CHANNEL_NOT_FOUND for a missing channel" do
    missing = "ch-http-none-" <> Ecto.UUID.generate()

    conn =
      request(
        :patch,
        "/api/chat/channels/#{missing}",
        key_headers(%{}, "http-u2"),
        %{"title" => "x"}
      )

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "CHANNEL_NOT_FOUND"
  end

  test "PATCH /channels/{id} → 409 CHANNEL_DISSOLVED for a dissolved channel" do
    cid = seed_owned_channel()

    dissolved =
      request(
        :post,
        "/api/chat/channels/#{cid}/dissolve",
        key_headers(%{}, "http-u3-dissolve")
      )

    assert dissolved.status == 200

    conn =
      request(
        :patch,
        "/api/chat/channels/#{cid}",
        key_headers(%{}, "http-u3"),
        %{"title" => "too late"}
      )

    assert conn.status == 409
    assert body_json(conn)["error"]["code"] == "CHANNEL_DISSOLVED"
  end

  # ------------------------------------------------------------- dissolve

  test "POST /channels/{id}/dissolve → 200 tombstone (channel_id, status, updated_at)" do
    cid = seed_owned_channel("Doomed")

    conn =
      request(
        :post,
        "/api/chat/channels/#{cid}/dissolve",
        key_headers(%{}, "http-d1")
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    json = body_json(conn)
    assert json["channel"]["channel_id"] == cid
    assert json["channel"]["status"] == "dissolved"
    assert is_binary(json["channel"]["updated_at"])
  end

  test "POST /channels/{id}/dissolve → 404 CHANNEL_NOT_FOUND for a missing channel" do
    missing = "ch-http-none2-" <> Ecto.UUID.generate()

    conn =
      request(
        :post,
        "/api/chat/channels/#{missing}/dissolve",
        key_headers(%{}, "http-d2")
      )

    assert conn.status == 404
    assert body_json(conn)["error"]["code"] == "CHANNEL_NOT_FOUND"
  end

  test "POST /channels/{id}/dissolve replay: same key → identical tombstone" do
    cid = seed_owned_channel()

    headers = key_headers(%{}, "http-d3")

    first = request(:post, "/api/chat/channels/#{cid}/dissolve", headers)
    second = request(:post, "/api/chat/channels/#{cid}/dissolve", headers)

    assert first.status == 200
    assert second.status == 200
    assert body_json(first) == body_json(second)
  end
end
