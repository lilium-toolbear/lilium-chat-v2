defmodule LiliumChatWeb.BotUploadsControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the Bot channel-scoped image upload
  routes (contract §9.17.1).

  Runs real conns through the ENTIRE endpoint pipeline (CORS → RequestId →
  router → `:bot_api` BotAuthPlug → controller), so bot-token auth, the
  `chat:messages:write` scope gate, the error envelope and X-Request-Id are
  all exercised. Fixtures mirror the bot-commands tests (BotFixtures: bot
  rows, token, command + allowed binding; ReadFixtures: channel row). The S3
  HEAD transport is the fake wired in `config/test.exs`; `:s3_fake_head` is
  set per-test.
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChatWeb.BotFixtures
  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Query, Repo}

  @bot "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee01"
  @bot2 "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee02"
  @owner "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @channel "11111111-1111-7111-8111-111111110001"
  @dissolved_channel "22222222-2222-7222-8222-222222220001"
  @token "lcbot_test-presign-token"
  @token2 "lcbot_test-finalize-token"
  @no_scope_token "lcbot_test-no-scope-token"

  setup do
    on_exit(fn -> Application.delete_env(:lilium_chat, :s3_fake_head) end)

    # Both bots are installed (allowed binding) in @channel.
    seed_bot(@owner, bot_id: @bot, display_name: "Upload Bot")
    seed_bot(@owner, bot_id: @bot2, display_name: "Other Upload Bot")
    seed_bot_token(@bot, @token, scopes: ["chat:messages:write"])
    seed_bot_token(@bot2, @token2, scopes: ["chat:messages:write"])
    # Token WITHOUT chat:messages:write (scope-gate test).
    seed_bot_token(@bot, @no_scope_token)

    cmd = seed_bot_command(@bot, "roll")
    seed_binding(@channel, cmd, bot_id: @bot)
    cmd2 = seed_bot_command(@bot2, "quiz")
    seed_binding(@channel, cmd2, bot_id: @bot2)

    seed_channel(@channel)
    seed_channel(@dissolved_channel, status: "dissolved")

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

  defp bot_headers(bot_token, extra \\ []) do
    [{"authorization", "Bearer " <> bot_token} | extra]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  defp error_of(conn) do
    body_json(conn)["error"]
  end

  defp presign_body(overlays \\ %{}) do
    Map.merge(
      %{
        "filename" => "photo.png",
        "mime_type" => "image/png",
        "size_bytes" => 12_345,
        "width" => 512,
        "height" => 512
      },
      overlays
    )
  end

  defp presign(bot_token, path_body, opts \\ []) do
    key = Keyword.get(opts, :key, "bot-presign-#{LiliumChat.Ids.uuidv7()}")
    channel = Keyword.get(opts, :channel, @channel)

    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{channel}/uploads/images/presign",
        bot_headers(bot_token, [{"idempotency-key", key}]),
        path_body
      )

    {conn.status, body_json(conn), conn}
  end

  defp attachment_row(attachment_id) do
    Query.rows(
      Repo.query(
        """
        SELECT attachment_id, owner_user_id, owner_bot_id, channel_id, kind,
               status, storage_key, url, width, height, blurhash
        FROM chat_v2.attachments
        WHERE attachment_id = $1
        """,
        [attachment_id]
      )
    )
    |> List.first()
  end

  # ------------------------------------------------------------- presign

  test "presign: 200 with the §8.1 wire shape and the bot-owned pending row" do
    {status, json, conn} = presign(@token, presign_body())

    assert status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]
    assert hd(get_resp_header(conn, "x-request-id")) =~ ~r/^req_/

    assert json["upload_method"] == "PUT"

    assert json["upload_headers"] == %{
             "Content-Type" => "image/png",
             "Cache-Control" => "public, max-age=31536000, immutable"
           }

    assert json["upload_url"] =~ ~r|^https://[^/]+/chat/|
    refute json["upload_url"] =~ "lilium-chat-attachments"
    assert json["upload_url"] =~ "X-Amz-Signature="
    assert json["expires_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/

    row = attachment_row(json["attachment_id"])
    assert row["owner_bot_id"] == @bot
    assert row["owner_user_id"] == nil
    assert row["channel_id"] == @channel
    assert row["kind"] == "image"
    assert row["status"] == "pending"
    assert row["storage_key"] == "chat/" <> json["attachment_id"]
  end

  test "presign: idempotent replay (same key + body) returns the identical response" do
    key = "bot-replay-key"

    {status1, json1, _} = presign(@token, presign_body(), key: key)
    assert status1 == 200

    {status2, json2, _} = presign(@token, presign_body(), key: key)
    assert status2 == 200
    assert json2 == json1
  end

  test "presign: same key with a different body → 409 IDEMPOTENCY_CONFLICT" do
    key = "bot-conflict-key"
    {status, _, _} = presign(@token, presign_body(), key: key)
    assert status == 200

    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/presign",
        bot_headers(@token, [{"idempotency-key", key}]),
        presign_body(%{"size_bytes" => 99_999})
      )

    assert conn.status == 409
    assert error_of(conn)["code"] == "IDEMPOTENCY_CONFLICT"
  end

  test "presign: missing Idempotency-Key → 422 (before the channel gate)" do
    # Unknown channel on purpose: the old Worker's route checks the key
    # BEFORE the DO gates, so 422 wins over 404.
    conn =
      request(
        :post,
        "/api/chat/bot/channels/33333333-3333-7333-8333-333333330001/uploads/images/presign",
        bot_headers(@token),
        presign_body()
      )

    assert conn.status == 422
    assert error_of(conn)["code"] == "INVALID_MESSAGE"
    assert error_of(conn)["message"] == "Idempotency-Key required"
  end

  test "presign: missing required body field → 422 (old route-level check)" do
    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/presign",
        bot_headers(@token, [{"idempotency-key", "bot-nosize"}]),
        %{"filename" => "photo.png", "mime_type" => "image/png"}
      )

    assert conn.status == 422
    assert error_of(conn)["code"] == "INVALID_MESSAGE"
    assert error_of(conn)["message"] == "filename, mime_type and size_bytes are required"
  end

  test "presign: channel not found → 404 CHANNEL_NOT_FOUND" do
    {status, json, _} =
      presign(@token, presign_body(), channel: "33333333-3333-7333-8333-333333330001")

    assert status == 404
    assert json["error"]["code"] == "CHANNEL_NOT_FOUND"
    assert json["error"]["message"] == "channel not found"
  end

  test "presign: dissolved channel → 409 CHANNEL_DISSOLVED (before the install gate)" do
    # No binding for @bot in the dissolved channel on purpose: 409 wins over
    # the FORBIDDEN install gate (old Worker gate order).
    {status, json, _} = presign(@token, presign_body(), channel: @dissolved_channel)

    assert status == 409
    assert json["error"]["code"] == "CHANNEL_DISSOLVED"
    assert json["error"]["message"] == "channel is dissolved"
  end

  test "presign: bot not installed in channel → 403 FORBIDDEN" do
    # @bot2 has no binding in @channel... wait, it does (setup). Use a
    # fresh bot without a binding.
    fresh_bot = "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee99"
    seed_bot(@owner, bot_id: fresh_bot, display_name: "Not Installed")
    token = "lcbot_test-not-installed"
    seed_bot_token(fresh_bot, token, scopes: ["chat:messages:write"])

    {status, json, _} = presign(token, presign_body())

    assert status == 403
    assert json["error"]["code"] == "FORBIDDEN"
    assert json["error"]["message"] == "bot not installed in channel"
  end

  test "presign: unsupported mime_type → 415 UNSUPPORTED_ATTACHMENT_TYPE" do
    {status, json, _} =
      presign(@token, presign_body(%{"mime_type" => "image/tiff"}))

    assert status == 415
    assert json["error"]["code"] == "UNSUPPORTED_ATTACHMENT_TYPE"
  end

  test "missing scope → 403 FORBIDDEN; missing token → 401 UNAUTHORIZED" do
    no_scope =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/presign",
        bot_headers(@no_scope_token, [{"idempotency-key", "bot-scope"}]),
        presign_body()
      )

    assert no_scope.status == 403
    assert error_of(no_scope)["code"] == "FORBIDDEN"
    assert error_of(no_scope)["message"] == "Missing scope: chat:messages:write"

    unauth =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/presign",
        [{"idempotency-key", "bot-unauth"}],
        presign_body()
      )

    assert unauth.status == 401
    assert error_of(unauth)["code"] == "UNAUTHORIZED"
  end

  # ------------------------------------------------------------- finalize

  test "finalize: 200 with the §8.2 projection after a matching HEAD" do
    {status, presigned, _} = presign(@token, presign_body())
    assert status == 200
    id = presigned["attachment_id"]

    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}}
    )

    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/#{id}/finalize",
        bot_headers(@token),
        %{"etag" => "\"abc123\""}
      )

    assert conn.status == 200
    json = body_json(conn)
    assert json["attachment"]["attachment_id"] == id
    assert json["attachment"]["kind"] == "image"
    assert json["attachment"]["filename"] == "photo.png"
    assert json["attachment"]["mime_type"] == "image/png"
    assert json["attachment"]["size_bytes"] == 12_345
    assert json["attachment"]["width"] == 512
    assert json["attachment"]["height"] == 512
    assert json["attachment"]["blurhash"] == nil
    assert json["attachment"]["url"] =~ "s3.kuma.homes/chat/" <> id

    assert attachment_row(id)["status"] == "finalized"
  end

  test "finalize: already-finalized attachment replays the projection (no HEAD)" do
    {status, presigned, _} = presign(@token, presign_body())
    assert status == 200
    id = presigned["attachment_id"]

    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}}
    )

    first =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/#{id}/finalize",
        bot_headers(@token),
        %{}
      )

    assert first.status == 200

    # Second finalize: the row is already finalized, so the S3 HEAD is
    # skipped — point the fake at a transport error to prove it.
    Application.put_env(:lilium_chat, :s3_fake_head, {:error, :econnrefused})

    second =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/#{id}/finalize",
        bot_headers(@token),
        %{}
      )

    assert second.status == 200
    assert body_json(second) == body_json(first)
  end

  test "finalize: attachment not found → 415 UNSUPPORTED_ATTACHMENT_TYPE" do
    unknown = "99999999-9999-7999-8999-999999999999"

    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/#{unknown}/finalize",
        bot_headers(@token),
        %{}
      )

    assert conn.status == 415
    assert error_of(conn)["code"] == "UNSUPPORTED_ATTACHMENT_TYPE"
    assert error_of(conn)["message"] == "attachment not found"
  end

  test "finalize: attachment owned by another bot → 403 FORBIDDEN" do
    {status, presigned, _} = presign(@token, presign_body())
    assert status == 200
    id = presigned["attachment_id"]

    # @bot2 IS installed in @channel, so the install gate passes and the
    # ownership gate rejects.
    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/#{id}/finalize",
        bot_headers(@token2),
        %{}
      )

    assert conn.status == 403
    assert error_of(conn)["code"] == "FORBIDDEN"
    assert error_of(conn)["message"] == "attachment does not belong to bot in this channel"
  end

  test "finalize: S3 HEAD mismatch → 415 UNSUPPORTED_ATTACHMENT_TYPE" do
    {status, presigned, _} = presign(@token, presign_body())
    assert status == 200
    id = presigned["attachment_id"]

    Application.put_env(:lilium_chat, :s3_fake_head, {:ok, 404, %{}})

    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/#{id}/finalize",
        bot_headers(@token),
        %{}
      )

    assert conn.status == 415
    assert error_of(conn)["code"] == "UNSUPPORTED_ATTACHMENT_TYPE"
    assert error_of(conn)["message"] == "S3 object missing or mismatch"

    # still pending — the flip only happens on a matching HEAD
    assert attachment_row(id)["status"] == "pending"
  end

  test "finalize: content-length mismatch → 415 UNSUPPORTED_ATTACHMENT_TYPE" do
    {status, presigned, _} = presign(@token, presign_body())
    assert status == 200
    id = presigned["attachment_id"]

    Application.put_env(
      :lilium_chat,
      :s3_fake_head,
      {:ok, 200, %{"content-type" => "image/png", "content-length" => "999"}}
    )

    conn =
      request(
        :post,
        "/api/chat/bot/channels/#{@channel}/uploads/images/#{id}/finalize",
        bot_headers(@token),
        %{}
      )

    assert conn.status == 415
    assert error_of(conn)["code"] == "UNSUPPORTED_ATTACHMENT_TYPE"
  end
end
