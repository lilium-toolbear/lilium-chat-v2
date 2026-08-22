defmodule LiliumChat.ChannelCommandsTest do
  @moduledoc """
  Domain tests for the channel command manifest + binding updates
  (issue #16, contract §9.4/§9.9).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.BotFixtures
  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{ChannelCommands, Repo}

  @user "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @ch1 "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee01"
  @bot "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee02"
  @official_bot "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeee03"

  setup do
    seed_channel(@ch1, kind: "channel")
    seed_membership(@ch1, @user, "owner")
    seed_membership(@ch1, @other, "member")
    seed_bot("owner-1", bot_id: @bot, display_name: "My Bot")
    :ok
  end

  defp command_row(bot_id, name, opts \\ []) do
    seed_bot_command(bot_id, name, opts)
  end

  defp seed_official_bot do
    Repo.query!(
      "INSERT INTO chat_v2.bot_apps (bot_id, owner_user_id, display_name, status, created_at, updated_at, visibility)
       VALUES ($1, $2, $3, 'active', $4, $4, 'official')
       ON CONFLICT (bot_id) DO NOTHING",
      [@official_bot, "owner-1", "Official Bot", DateTime.utc_now()],
      type: true
    )
  end

  # -------------------------------------------------------------- manifest

  test "list: non-member → FORBIDDEN; unknown channel → CHANNEL_NOT_FOUND" do
    assert {:error, err} = ChannelCommands.list("stranger", @ch1)
    assert err.code == "FORBIDDEN"
    assert err.message == "not a channel member"

    assert {:error, err} = ChannelCommands.list(@user, Ecto.UUID.generate())
    assert err.code == "CHANNEL_NOT_FOUND"
  end

  test "list: dissolved channel → CHANNEL_DISSOLVED" do
    Repo.query!(
      "UPDATE chat_v2.channels SET status = 'dissolved' WHERE channel_id = $1",
      [@ch1],
      type: true
    )

    assert {:error, err} = ChannelCommands.list(@user, @ch1)
    assert err.code == "CHANNEL_DISSOLVED"
  end

  test "list: DM channel → {version: 0, items: []}" do
    dm = "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeee04"
    seed_channel(dm, kind: "dm")
    seed_membership(dm, @user, "member")

    assert {:ok, %{"version" => 0, "items" => []}} = ChannelCommands.list(@user, dm)
  end

  test "list: member sees /help but not /permission; owner sees both" do
    manifest = ChannelCommands.list(@other, @ch1)

    # member role
    assert {:ok, member_manifest} = manifest
    names = Enum.map(member_manifest["items"], & &1["name"])
    assert "help" in names
    refute "permission" in names

    # owner role
    assert {:ok, owner_manifest} = ChannelCommands.list(@user, @ch1)
    owner_names = Enum.map(owner_manifest["items"], & &1["name"])
    assert "permission" in owner_names
    assert "help" in owner_names
  end

  test "list: allowed binding appears with effective permission; role filter hides admin-only from members" do
    cmd_id = command_row(@bot, "admin-tool", permission: "admin")

    seed_binding(@ch1, cmd_id,
      bot_id: @bot,
      snapshot: snapshot(cmd_id, name: "admin-tool", permission: "admin")
    )

    assert {:ok, owner_view} = ChannelCommands.list(@user, @ch1)
    tool = Enum.find(owner_view["items"], &(&1["name"] == "admin-tool"))
    assert tool["effective_member_permission"] == "admin"

    assert {:ok, member_view} = ChannelCommands.list(@other, @ch1)
    refute Enum.find(member_view["items"], &(&1["name"] == "admin-tool"))
  end

  test "list: items sorted by name then bot_command_id; version comes from the channel" do
    a = command_row(@bot, "zeta")
    b = command_row(@bot, "alpha")
    seed_binding(@ch1, a, bot_id: @bot, snapshot: snapshot(a, name: "zeta"))
    seed_binding(@ch1, b, bot_id: @bot, snapshot: snapshot(b, name: "alpha"))

    # bump the stored manifest version
    Repo.query!(
      "UPDATE chat_v2.channels SET command_manifest_version = 7 WHERE channel_id = $1",
      [@ch1],
      type: true
    )

    assert {:ok, manifest} = ChannelCommands.list(@user, @ch1)
    assert manifest["version"] == 7

    names = Enum.map(manifest["items"], & &1["name"])
    assert "alpha" in names
    assert "zeta" in names
    assert names == Enum.sort(names)
  end

  test "full: no role filtering (bootstrap shape) — admin-only items visible to members" do
    cmd_id = command_row(@bot, "admin-tool", permission: "admin")

    seed_binding(@ch1, cmd_id,
      bot_id: @bot,
      snapshot: snapshot(cmd_id, name: "admin-tool", permission: "admin")
    )

    assert {:ok, full} = ChannelCommands.full(@other, @ch1)
    assert Enum.find(full["items"], &(&1["name"] == "admin-tool"))
  end

  test "official commands auto-appear; a blocked official binding hides them" do
    seed_official_bot()
    cmd_id = seed_bot_command(@official_bot, "official-tool")

    assert {:ok, manifest} = ChannelCommands.list(@user, @ch1)
    official = Enum.find(manifest["items"], &(&1["name"] == "official-tool"))
    assert official != nil
    assert official["bot"]["bot_id"] == @official_bot

    # block it
    seed_binding(@ch1, cmd_id, bot_id: @official_bot, status: "blocked")

    assert {:ok, manifest2} = ChannelCommands.list(@user, @ch1)
    refute Enum.find(manifest2["items"], &(&1["name"] == "official-tool"))
  end

  # ----------------------------------------------------------- bindings

  test "update_binding: allowed → response shape + row + version bump + event" do
    cmd_id = command_row(@bot, "roll")

    assert {:ok,
            %{"bot_command_id" => ^cmd_id, "status" => "allowed", "permission_override" => nil}} =
             ChannelCommands.update_binding(@user, @ch1, cmd_id, %{
               idempotency_key: "k1",
               status: "allowed",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    binding =
      Repo.query(
        "SELECT status, permission_override, updated_by_user_id FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
        [@ch1, cmd_id]
      )
      |> LiliumChat.Query.rows()
      |> List.first()

    assert binding["status"] == "allowed"
    assert binding["updated_by_user_id"] == @user

    version =
      Repo.query(
        "SELECT command_manifest_version FROM chat_v2.channels WHERE channel_id = $1",
        [@ch1]
      )
      |> LiliumChat.Query.rows()
      |> List.first()
      |> Map.get("command_manifest_version")

    assert version == 1

    event =
      Repo.query(
        "SELECT event_type, actor_kind, actor_id FROM chat_v2.events WHERE channel_id = $1 AND event_type = 'command.binding_updated'",
        [@ch1]
      )
      |> LiliumChat.Query.rows()
      |> List.first()

    assert event["actor_kind"] == "user"
    assert event["actor_id"] == @user
  end

  test "update_binding: permission_override is persisted" do
    cmd_id = command_row(@bot, "roll")

    assert {:ok, %{"permission_override" => "admin"}} =
             ChannelCommands.update_binding(@user, @ch1, cmd_id, %{
               idempotency_key: "k1",
               status: "allowed",
               permission_override: "admin",
               stateful_max_ttl_seconds: nil
             })

    binding =
      Repo.query(
        "SELECT permission_override FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
        [@ch1, cmd_id]
      )
      |> LiliumChat.Query.rows()
      |> List.first()

    assert binding["permission_override"] == "admin"
  end

  test "update_binding: blocked removes from manifest view" do
    cmd_id = command_row(@bot, "roll")

    assert {:ok, _} =
             ChannelCommands.update_binding(@user, @ch1, cmd_id, %{
               idempotency_key: "k1",
               status: "allowed",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    assert {:ok, %{"status" => "blocked"}} =
             ChannelCommands.update_binding(@user, @ch1, cmd_id, %{
               idempotency_key: "k2",
               status: "blocked",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    assert {:ok, manifest} = ChannelCommands.list(@user, @ch1)
    refute Enum.find(manifest["items"], &(&1["name"] == "roll"))
  end

  test "update_binding: blocking an unknown non-official command → COMMAND_NOT_FOUND" do
    cmd_id = command_row(@bot, "roll")

    assert {:error, err} =
             ChannelCommands.update_binding(@user, @ch1, cmd_id, %{
               idempotency_key: "k1",
               status: "blocked",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    assert err.code == "COMMAND_NOT_FOUND"
    assert err.message == "command binding not found"
  end

  test "update_binding: allowed official command → OFFICIAL_COMMAND_AUTO_ALLOWED" do
    seed_official_bot()
    cmd_id = seed_bot_command(@official_bot, "official-tool")

    assert {:error, err} =
             ChannelCommands.update_binding(@user, @ch1, cmd_id, %{
               idempotency_key: "k1",
               status: "allowed",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    assert err.code == "OFFICIAL_COMMAND_AUTO_ALLOWED"
  end

  test "update_binding: re-allowing a blocked official command deletes the row" do
    seed_official_bot()
    cmd_id = seed_bot_command(@official_bot, "official-tool")
    seed_binding(@ch1, cmd_id, bot_id: @official_bot, status: "blocked")

    assert {:ok, %{"status" => "allowed"}} =
             ChannelCommands.update_binding(@user, @ch1, cmd_id, %{
               idempotency_key: "k1",
               status: "allowed",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    binding =
      Repo.query(
        "SELECT status FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
        [@ch1, cmd_id]
      )
      |> LiliumChat.Query.rows()

    assert binding == []

    # and it is visible again (official auto-allowed)
    assert {:ok, manifest} = ChannelCommands.list(@user, @ch1)
    assert Enum.find(manifest["items"], &(&1["name"] == "official-tool"))
  end

  test "update_binding: non-owner/admin → FORBIDDEN" do
    cmd_id = command_row(@bot, "roll")

    assert {:error, err} =
             ChannelCommands.update_binding(@other, @ch1, cmd_id, %{
               idempotency_key: "k1",
               status: "allowed",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    assert err.code == "FORBIDDEN"
    assert err.message == "only owner/admin may update command bindings"
  end

  test "update_binding: DM channel → UNSUPPORTED_CHANNEL_KIND; unknown channel → CHANNEL_NOT_FOUND" do
    cmd_id = command_row(@bot, "roll")

    dm = "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeee04"
    seed_channel(dm, kind: "dm")
    seed_membership(dm, @user, "member")

    assert {:error, err} =
             ChannelCommands.update_binding(@user, dm, cmd_id, %{
               idempotency_key: "k1",
               status: "allowed",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    assert err.code == "UNSUPPORTED_CHANNEL_KIND"

    assert {:error, err} =
             ChannelCommands.update_binding(@user, Ecto.UUID.generate(), cmd_id, %{
               idempotency_key: "k2",
               status: "allowed",
               permission_override: nil,
               stateful_max_ttl_seconds: nil
             })

    assert err.code == "CHANNEL_NOT_FOUND"
  end

  test "update_binding: idempotent replay returns the stored response" do
    cmd_id = command_row(@bot, "roll")

    attrs = %{
      idempotency_key: "k1",
      status: "allowed",
      permission_override: nil,
      stateful_max_ttl_seconds: nil
    }

    assert {:ok, response} = ChannelCommands.update_binding(@user, @ch1, cmd_id, attrs)
    assert {:ok, replayed} = ChannelCommands.update_binding(@user, @ch1, cmd_id, attrs)
    assert replayed == response

    # version bumped exactly once
    version =
      Repo.query(
        "SELECT command_manifest_version FROM chat_v2.channels WHERE channel_id = $1",
        [@ch1]
      )
      |> LiliumChat.Query.rows()
      |> List.first()
      |> Map.get("command_manifest_version")

    assert version == 1
  end
end
