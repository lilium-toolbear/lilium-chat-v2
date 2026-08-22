defmodule LiliumChatWeb.BotFixtures do
  @moduledoc """
  Shared seed helpers for the bot-domain tests (issue #16).

  Import into a `LiliumChat.DataCase` / `LiliumChatWeb.ConnCase` module:

      import LiliumChatWeb.BotFixtures

  All helpers insert real `chat_v2` rows so the bot domain can be exercised
  end-to-end (catalog sync, token verify, manifests, bindings).
  """

  alias LiliumChat.BotTokens
  alias LiliumChat.Repo

  @doc "Insert a `bot_apps` row. Returns the bot_id."
  def seed_bot(owner_user_id, opts \\ []) do
    bot_id = Keyword.get(opts, :bot_id) || Ecto.UUID.generate()
    now = Keyword.get(opts, :created_at, DateTime.utc_now())

    Repo.query!(
      """
      INSERT INTO chat_v2.bot_apps
        (bot_id, owner_user_id, display_name, avatar_url, description,
         visibility, status, created_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        bot_id,
        owner_user_id,
        Keyword.get(opts, :display_name, "Test Bot"),
        Keyword.get(opts, :avatar_url, nil),
        Keyword.get(opts, :description, nil),
        Keyword.get(opts, :visibility, "private"),
        Keyword.get(opts, :status, "active"),
        now,
        Keyword.get(opts, :updated_at, now)
      ],
      type: true
    )

    bot_id
  end

  @doc "Insert a `bot_tokens` row hashing `plaintext` (SHA-256 stored)."
  def seed_bot_token(bot_id, plaintext, opts \\ []) do
    token_id = Keyword.get(opts, :token_id) || Ecto.UUID.generate()
    now = Keyword.get(opts, :created_at, DateTime.utc_now())

    Repo.query!(
      """
      INSERT INTO chat_v2.bot_tokens
        (token_id, bot_id, name, token_hash, scopes, created_at, expires_at, revoked_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [
        token_id,
        bot_id,
        Keyword.get(opts, :name, "test"),
        BotTokens.hash(plaintext),
        Jason.encode!(
          Keyword.get(opts, :scopes, ["chat:runtime:connect", "chat:commands:manage"])
        ),
        now,
        Keyword.get(opts, :expires_at),
        Keyword.get(opts, :revoked_at)
      ],
      type: true
    )

    token_id
  end

  @doc """
  A valid command-binding snapshot map (the shape
  `CommandManifest.parse_snapshot/1` accepts).
  """
  def snapshot(bot_command_id, opts \\ []) do
    %{
      "bot_command_id" => bot_command_id,
      "name" => Keyword.get(opts, :name, "test"),
      "aliases" => Keyword.get(opts, :aliases, []),
      "description" => Keyword.get(opts, :description, "test command"),
      "help_text" => Keyword.get(opts, :help_text, ""),
      "bot" => %{
        "bot_id" => Keyword.get(opts, :bot_id, "11111111-1111-7111-8111-111111111111"),
        "display_name" => Keyword.get(opts, :bot_name, "Test Bot"),
        "avatar_url" => Keyword.get(opts, :avatar_url, nil)
      },
      "options" => Keyword.get(opts, :options, []),
      "default_member_permission" => Keyword.get(opts, :permission, "member"),
      "execution" => Keyword.get(opts, :execution, %{"mode" => "stateless"})
    }
  end

  @doc """
  Insert a `bot_commands` row plus its `bot_command_names` (canonical +
  aliases) and `bot_command_aliases` rows. Returns the bot_command_id.
  """
  def seed_bot_command(bot_id, name, opts \\ []) do
    command_id = Keyword.get(opts, :bot_command_id) || Ecto.UUID.generate()
    now = Keyword.get(opts, :created_at, DateTime.utc_now())
    aliases = Keyword.get(opts, :aliases, [])

    Repo.query!(
      """
      INSERT INTO chat_v2.bot_commands
        (bot_command_id, bot_id, name, description, help_text, options_json,
         default_member_permission, execution_mode, stateful_config_json,
         schema_version, definition_hash, status, created_at, updated_at, deleted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13, NULL)
      """,
      [
        command_id,
        bot_id,
        name,
        Keyword.get(opts, :description, "test command"),
        Keyword.get(opts, :help_text, ""),
        Keyword.get(opts, :options, []),
        Keyword.get(opts, :permission, "member"),
        Keyword.get(opts, :execution_mode, "stateless"),
        Keyword.get(opts, :stateful_config),
        Keyword.get(opts, :schema_version, 1),
        Keyword.get(opts, :definition_hash) ||
          :crypto.hash(:sha256, name) |> Base.encode16(case: :lower),
        Keyword.get(opts, :status, "active"),
        now
      ],
      type: true
    )

    for alias <- aliases do
      Repo.query!(
        "INSERT INTO chat_v2.bot_command_aliases (bot_command_id, bot_id, alias, created_at) VALUES ($1, $2, $3, $4)",
        [command_id, bot_id, alias, now]
      )

      Repo.query!(
        "INSERT INTO chat_v2.bot_command_names (slash_token, bot_command_id, bot_id, kind, created_at) VALUES ($1, $2, $3, 'alias', $4)",
        [alias, command_id, bot_id, now]
      )
    end

    Repo.query!(
      "INSERT INTO chat_v2.bot_command_names (slash_token, bot_command_id, bot_id, kind, created_at) VALUES ($1, $2, $3, 'canonical', $4)",
      [name, command_id, bot_id, now]
    )

    command_id
  end

  @doc "Insert a `channel_command_bindings` row (default: a valid allowed snapshot)."
  def seed_binding(channel_id, bot_command_id, opts \\ []) do
    bot_id = Keyword.get(opts, :bot_id, "11111111-1111-7111-8111-111111111111")
    snapshot = Keyword.get(opts, :snapshot, snapshot(bot_command_id))

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_command_bindings
        (channel_id, bot_command_id, bot_id, status, permission_override,
         command_snapshot_json, stateful_max_ttl_seconds, updated_by_user_id, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        channel_id,
        bot_command_id,
        Keyword.get(opts, :bot_id, bot_id),
        Keyword.get(opts, :status, "allowed"),
        Keyword.get(opts, :permission_override, nil),
        snapshot,
        Keyword.get(opts, :stateful_max_ttl_seconds, nil),
        Keyword.get(opts, :updated_by_user_id, "updater"),
        Keyword.get(opts, :created_at, DateTime.utc_now())
      ],
      type: true
    )

    bot_command_id
  end
end
