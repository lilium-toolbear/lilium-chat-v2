defmodule LiliumChat.BootstrapTest do
  @moduledoc """
  Domain tests for the bootstrap read path (issue #5).

  Covers:
  * empty state (no channels) → correct wire shape
  * populated state → channels, messages, pins, event_state
  * read-only assertion (A12)
  * profile batch (A10)
  * per-channel cursor map consistency
  * active channel selection (?channel_id=)
  """

  use LiliumChat.DataCase, async: false

  alias LiliumChat.Bootstrap
  alias LiliumChat.Observability.ReadPath
  alias LiliumChat.Repo

  @user_id "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other_user "11111111-2222-7333-8444-555555555555"
  @ch1 "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee01"
  @ch2 "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee02"

  setup do
    # Clean slate for each test (sandbox handles rollback)
    :ok
  end

  # ------------------------------------------------------------- empty state

  test "empty state: user with no channels returns correct shape" do
    result = Bootstrap.fetch(@user_id, nil)

    assert result["me"]["user_id"] == @user_id
    # fallback
    assert result["me"]["display_name"] == "user-6f1e2c3d"
    assert result["me"]["avatar_url"] == nil
    assert result["channels"] == []
    assert result["active_channel"] == nil
    assert result["messages"] == %{"items" => [], "next_cursor" => nil}
    assert result["channel_pins"] == []
    assert result["event_state"] == %{"per_channel" => %{}}
  end

  test "empty state: read-only (A12)" do
    {result, stats} = ReadPath.run(fn -> Bootstrap.fetch(@user_id, nil) end)

    assert stats.writes == 0
    # at least the main channel query
    assert stats.reads > 0
    assert result["channels"] == []
  end

  # ------------------------------------------------------- populated state

  test "populated: channels list with correct fields" do
    seed_channel(@ch1, "General", "channel")
    seed_membership(@ch1, @user_id, "member")
    seed_event(@ch1, "01JAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    seed_message(@ch1, @other_user, "hello world")

    result = Bootstrap.fetch(@user_id, nil)

    assert length(result["channels"]) == 1
    ch = List.first(result["channels"])
    assert ch["channel_id"] == @ch1
    assert ch["kind"] == "channel"
    assert ch["visibility"] == "private"
    assert ch["title"] == "General"
    assert ch["member_count"] == 1
    assert ch["status"] == "active"
    assert ch["role"] == "member"
    assert ch["last_event_id"] == "01JAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    assert ch["last_message_at"] != nil
    assert ch["last_message_preview"] =~ "hello world"
    assert ch["unread_count"] == 0
    assert ch["last_read_event_id"] == nil
  end

  test "populated: event_state.per_channel matches channel_summary last_event_id" do
    seed_channel(@ch1, "General", "channel")
    seed_membership(@ch1, @user_id, "member")
    seed_event(@ch1, "01JAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    seed_event(@ch1, "01JBBBBBBBBBBBBBBBBBBBBBBBBBBBB")

    result = Bootstrap.fetch(@user_id, nil)

    ch = List.first(result["channels"])
    per_channel = result["event_state"]["per_channel"]

    # The per_channel map should have the channel
    assert per_channel[@ch1] == ch["last_event_id"]
    # And it should be the latest event
    assert per_channel[@ch1] == "01JBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  end

  test "populated: messages returned for active channel" do
    seed_channel(@ch1, "General", "channel")
    seed_membership(@ch1, @user_id, "member")
    # Explicit event_ids ensure deterministic ordering (UUIDv7 is time-ordered)
    seed_message(@ch1, @other_user, "first message", nil, "01JAAAAAAAAAAAAAAAAAAAAAAAAA01")
    seed_message(@ch1, @other_user, "second message", nil, "01JBBBBBBBBBBBBBBBBBBBBBBBBBB02")

    result = Bootstrap.fetch(@user_id, nil)

    messages = result["messages"]
    assert length(messages["items"]) == 2
    assert messages["next_cursor"] == nil

    # Messages are in chronological order (oldest first in the list)
    first = List.first(messages["items"])
    assert first["text"] == "first message"
    assert first["type"] == "text"
    assert first["status"] == "active"
    assert first["sender"]["kind"] == "user"
    assert first["sender"]["user"]["user_id"] == @other_user
  end

  test "populated: channel_pins returned for active channel" do
    seed_channel(@ch1, "General", "channel")
    seed_membership(@ch1, @user_id, "member")
    seed_pin(@ch1, "msg-1")

    result = Bootstrap.fetch(@user_id, nil)

    pins = result["channel_pins"]
    assert length(pins) == 1
    assert hd(pins)["channel_id"] == @ch1
  end

  test "active channel selection: ?channel_id= picks the right channel" do
    seed_channel(@ch1, "Channel 1", "channel")
    seed_channel(@ch2, "Channel 2", "channel")
    seed_membership(@ch1, @user_id, "member")
    seed_membership(@ch2, @user_id, "owner")
    seed_message(@ch2, @other_user, "important")

    result = Bootstrap.fetch(@user_id, @ch2)

    assert result["active_channel"]["channel_id"] == @ch2
    assert result["active_channel"]["title"] == "Channel 2"
    assert result["active_channel"]["role"] == "owner"

    # Messages should be from ch2
    messages = result["messages"]
    assert length(messages["items"]) == 1
    assert hd(messages["items"])["text"] == "important"
  end

  test "active channel: unknown channel_id → active_channel is nil" do
    seed_channel(@ch1, "Channel 1", "channel")
    seed_membership(@ch1, @user_id, "member")

    unknown = "99999999-9999-7999-8999-999999999999"
    result = Bootstrap.fetch(@user_id, unknown)

    # The requested channel is not in the user's list, so active_channel = nil
    assert result["active_channel"] == nil
    assert result["messages"] == %{"items" => [], "next_cursor" => nil}
  end

  test "active channel: channel_id matching a user's channel → command_manifest present" do
    seed_channel(@ch1, "General", "channel")
    seed_membership(@ch1, @user_id, "member")
    seed_command_binding(@ch1)

    result = Bootstrap.fetch(@user_id, @ch1)

    manifest = result["command_manifest"]
    assert manifest != nil
    # version comes from channels.command_manifest_version (0 for a freshly
    # seeded channel — the binding was inserted directly, not via update).
    assert manifest["version"] == 0
    # full bootstrap manifest = allowed binding + platform /help (the member
    # role does not get /permission).
    names = manifest["items"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert "help" in names
    assert length(manifest["items"]) == 2
  end

  test "DM channel: channel_pins always empty" do
    seed_channel(@ch1, "Alice", "dm")
    seed_membership(@ch1, @user_id, "member")
    seed_pin(@ch1, "msg-1")

    result = Bootstrap.fetch(@user_id, nil)

    assert result["channel_pins"] == []
  end

  test "read-only: no write statements in populated bootstrap (A12)" do
    seed_channel(@ch1, "General", "channel")
    seed_membership(@ch1, @user_id, "member")
    seed_event(@ch1, "01JAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    seed_message(@ch1, @other_user, "test")
    seed_pin(@ch1, "msg-1")

    {_result, stats} = ReadPath.run(fn -> Bootstrap.fetch(@user_id, nil) end)

    assert stats.writes == 0
    # Bounded query count: main(1) + messages(1) + pins(1) + profiles(1) = 4
    # (command_manifest is 0 here since no channel_id param)
    assert stats.reads >= 3
    assert stats.reads <= 6
  end

  test "profile batch: display_name resolved from public.users (A10)" do
    seed_channel(@ch1, "General", "channel")
    seed_membership(@ch1, @user_id, "member")
    seed_message(@ch1, @other_user, "hi")
    seed_user_profile(@other_user, "Alice", "https://example.com/a.png")

    result = Bootstrap.fetch(@user_id, nil)

    # The last_message_preview should use the resolved display name
    ch = List.first(result["channels"])
    assert ch["last_message_preview"] == "Alice: hi"
  end

  test "profile: me resolved from public.users" do
    seed_user_profile(@user_id, "Kuma", "https://example.com/k.png")

    result = Bootstrap.fetch(@user_id, nil)

    assert result["me"]["display_name"] == "Kuma"
    assert result["me"]["avatar_url"] == "https://example.com/k.png"
  end

  test "profile: missing user gets fallback" do
    # No profile row for @user_id
    result = Bootstrap.fetch(@user_id, nil)

    assert result["me"]["user_id"] == @user_id
    assert result["me"]["display_name"] == "user-6f1e2c3d"
    assert result["me"]["avatar_url"] == nil
  end

  # ------------------------------------------------------------- helpers

  defp seed_channel(channel_id, title, kind) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.channels (channel_id, kind, visibility, title, topic, avatar_url,
        status, created_by, created_at, updated_at, member_count, membership_version)
      VALUES ($1, $2, 'private', $3, NULL, NULL, 'active', $4, $5, $5, 1, 1)
      """,
      [channel_id, kind, title, @user_id, now],
      type: true
    )
  end

  defp seed_membership(channel_id, user_id, role) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, status)
      VALUES ($1, $2, $3, $4, 'active')
      """,
      [channel_id, user_id, role, now],
      type: true
    )
  end

  defp seed_event(channel_id, event_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.events (event_id, event_type, channel_id, actor_kind, actor_id,
        actor_session_id, payload, membership_version_at_event, occurred_at)
      VALUES ($1, 'message.created', $2, 'user', 'test', NULL, '{}', 1, $3)
      """,
      [event_id, channel_id, now],
      type: true
    )
  end

  defp seed_message(channel_id, sender_id, text, ts \\ nil, event_id \\ nil) do
    now = ts || DateTime.utc_now()
    message_id = Ecto.UUID.generate()
    evt_id = event_id || Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (message_id, command_id, dedupe_principal_key, channel_id,
        sender_kind, sender_user_id, type, format, status, text, stream_state,
        created_at, updated_at, event_id)
      VALUES ($1, $2, $2, $3, 'user', $4, 'text', 'plain', 'active', $5, 'final', $6, $6, $7)
      """,
      [message_id, Ecto.UUID.generate(), channel_id, sender_id, text, now, evt_id],
      type: true
    )
  end

  defp seed_pin(channel_id, source_message_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_pins (pin_id, channel_id, pin_kind, pin_owner_kind,
        pin_owner_id, priority, session_id, source_message_id, pinned_by_user_id,
        pinned_at, expires_at, last_pin_event_id, message_projection_json,
        created_at, updated_at)
      VALUES ($1, $2, 'message', 'user', $3, 0, NULL, $4, $3, $5, NULL, $6, '{}', $5, $5)
      """,
      [Ecto.UUID.generate(), channel_id, @user_id, source_message_id, now, Ecto.UUID.generate()],
      type: true
    )
  end

  defp seed_command_binding(channel_id) do
    now = DateTime.utc_now()
    bot_id = Ecto.UUID.generate()
    cmd_id = Ecto.UUID.generate()

    snapshot =
      %{
        "bot_command_id" => cmd_id,
        "name" => "/test",
        "aliases" => [],
        "description" => "Test command",
        "help_text" => "help text",
        "bot" => %{"bot_id" => bot_id, "display_name" => "Test Bot", "avatar_url" => nil},
        "options" => [],
        "default_member_permission" => "member",
        "execution" => %{"mode" => "stateless"}
      }

    Repo.query!(
      """
      INSERT INTO chat_v2.bot_commands (bot_command_id, bot_id, name, description, options_json,
        default_member_permission, schema_version, definition_hash, created_at,
        updated_at, execution_mode, status, help_text)
      VALUES ($1, $2, '/test', 'Test command', '{}', 'member', 1, 'hash', $3, $3,
        'stateless', 'active', 'help text')
      """,
      [cmd_id, bot_id, now],
      type: true
    )

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_command_bindings (channel_id, bot_command_id, bot_id, status,
        permission_override, command_snapshot_json, stateful_max_ttl_seconds,
        updated_by_user_id, updated_at)
      VALUES ($1, $2, $3, 'allowed', NULL, $4, NULL, $5, $6)
      """,
      [channel_id, cmd_id, bot_id, snapshot, @user_id, now],
      type: true
    )
  end

  defp seed_user_profile(user_id, full_name, avatar_url) do
    Repo.query!(
      """
      INSERT INTO public.users (user_id, full_name, avatar_url)
      VALUES ($1, $2, $3)
      ON CONFLICT (user_id) DO UPDATE SET full_name = $2, avatar_url = $3
      """,
      [user_id, full_name, avatar_url]
    )
  end
end
