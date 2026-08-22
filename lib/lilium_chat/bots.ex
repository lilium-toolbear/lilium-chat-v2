defmodule LiliumChat.Bots do
  @moduledoc """
  Bot registry CRUD — developer + admin APIs (contract §9.10/§9.11, issue #16).

  Port of the old Worker's `BotRegistry` DO (createBot / listBotsForOwner /
  getBot / updateBot / listBotTokens / createBotToken / revokeBotToken /
  listBotsAdmin). Timestamps are `timestamptz` columns decoded via
  `type: true` and formatted with `LiliumChat.Projections.format_ts/1`.
  """

  alias LiliumChat.{BotTokens, Errors, Ids, Projections, Query, Repo}

  @visibilities ~w(private unlisted public official)
  @statuses ~w(active disabled deleted)

  # --------------------------------------------------------------------------
  # Offset cursors (object.ts encodeOffsetCursor / decodeOffsetCursor)
  # --------------------------------------------------------------------------

  @doc "base64url(offset) without padding."
  def encode_offset_cursor(offset) do
    Integer.to_string(offset) |> Base.url_encode64(padding: false)
  end

  @doc "Inverse of `encode_offset_cursor/1`; bad/missing cursors decode to 0."
  def decode_offset_cursor(nil), do: 0
  def decode_offset_cursor(""), do: 0

  def decode_offset_cursor(cursor) when is_binary(cursor) do
    normalized =
      cursor
      |> String.replace("-", "+")
      |> String.replace("_", "/")

    padded = normalized <> String.duplicate("=", rem(4 - rem(byte_size(normalized), 4), 4))

    case Base.url_decode64(padded, padding: true) do
      {:ok, digits} -> parseInt_nonneg(digits)
      :error -> 0
    end
  end

  # JS Number.parseInt: leading integer prefix, else 0; negatives -> 0.
  defp parseInt_nonneg(digits) do
    case Regex.run(~r/^\d+/, digits) do
      [head] -> String.to_integer(head)
      nil -> 0
    end
  end

  @doc "JS `parseInt(limit) |> clamp(1, 100)` with a default for NaN."
  def parse_limit(value, default) do
    case value do
      nil ->
        default

      "" ->
        default

      s when is_binary(s) ->
        case Regex.run(~r/^-?\d+/, s) do
          [head] ->
            v = String.to_integer(head)
            v = if v < 1, do: 1, else: v
            if v > 100, do: 100, else: v

          nil ->
            default
        end
    end
  end

  # --------------------------------------------------------------------------
  # Projection
  # --------------------------------------------------------------------------

  @doc "BotAppSummary (create/get/patch — no command_count)."
  def project_bot(row) do
    %{
      "bot_id" => row["bot_id"],
      "owner_user_id" => row["owner_user_id"],
      "display_name" => row["display_name"],
      "avatar_url" => row["avatar_url"],
      "description" => row["description"],
      "visibility" => row["visibility"],
      "status" => row["status"],
      "created_at" => Projections.format_ts(row["created_at"]),
      "updated_at" => Projections.format_ts(row["updated_at"])
    }
  end

  @doc "BotAppSummary + command_count (list endpoints only)."
  def project_bot_with_count(row) do
    project_bot(row) |> Map.put("command_count", row["command_count"])
  end

  # --------------------------------------------------------------------------
  # create
  # --------------------------------------------------------------------------

  def create(owner_user_id, attrs) do
    display_name = attrs[:display_name] || attrs["display_name"]

    unless is_binary(display_name) and String.trim(display_name) != "" do
      {:error, Errors.new("INVALID_MESSAGE", "owner_user_id and display_name required")}
    else
      display_name = String.trim(display_name)
      visibility = attrs[:visibility] || attrs["visibility"] || "private"
      visibility = if visibility in @visibilities, do: visibility, else: "private"
      avatar_url = attr(attrs, :avatar_url)
      description = attr(attrs, :description)
      issue = fetch_bool(attrs, :issue_initial_token, true)
      token_name = attr_or_default(attrs, :initial_token_name, "default")
      scopes = resolve_scopes(attrs[:initial_token_scopes] || attrs["initial_token_scopes"])

      now = DateTime.utc_now()
      bot_id = Ids.uuidv7()

      {token_id, plaintext, hash} =
        if issue do
          plaintext = BotTokens.generate_plaintext()
          {Ids.uuidv7(), plaintext, BotTokens.hash(plaintext)}
        else
          {nil, nil, nil}
        end

      result =
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO chat_v2.bot_apps
              (bot_id, owner_user_id, display_name, avatar_url, description,
               visibility, status, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, 'active', $7, $7)
            """,
            [bot_id, owner_user_id, display_name, avatar_url, description, visibility, now]
          )

          if token_id do
            Repo.query!(
              """
              INSERT INTO chat_v2.bot_tokens
                (token_id, bot_id, name, token_hash, scopes, created_at, expires_at)
              VALUES ($1, $2, $3, $4, $5, $6, $7)
              """,
              [
                token_id,
                bot_id,
                token_name,
                hash,
                BotTokens.scopes_json(scopes),
                now,
                attrs[:initial_token_expires_at] || attrs["initial_token_expires_at"] || nil
              ]
            )
          end
        end)

      case result do
        {:ok, _} ->
          row = get_row(bot_id)
          expires = attrs[:initial_token_expires_at] || attrs["initial_token_expires_at"]
          token_map = initial_token_map(token_id, token_name, scopes, plaintext, now, expires)

          {:ok, %{bot: project_bot(row), initial_token: token_map}}

        {:error, _} ->
          {:error, Errors.new("BOT_NOT_FOUND", "bot not found")}
      end
    end
  end

  defp initial_token_map(nil, _name, _scopes, _plaintext, _now, _expires), do: nil

  defp initial_token_map(token_id, name, scopes, plaintext, now, expires) do
    %{
      token_id: token_id,
      name: name,
      scopes: scopes,
      plaintext: plaintext,
      created_at: Projections.format_ts(now),
      expires_at: Projections.format_ts(expires)
    }
  end

  # --------------------------------------------------------------------------
  # list (owner + admin)
  # --------------------------------------------------------------------------

  def list_for_owner(owner_user_id, opts \\ %{}) do
    limit = parse_limit(opt(opts, :limit), 20)
    offset = decode_offset_cursor(opt(opts, :cursor))

    rows =
      Query.rows(
        Repo.query(
          """
          SELECT b.bot_id, b.owner_user_id, b.display_name, b.avatar_url, b.description,
                 b.visibility, b.status, b.created_at, b.updated_at,
                 (SELECT COUNT(*) FROM chat_v2.bot_commands c
                   WHERE c.bot_id = b.bot_id AND c.status = 'active' AND c.deleted_at IS NULL)
                   AS command_count
          FROM chat_v2.bot_apps b
          WHERE b.owner_user_id = $1 AND b.status != 'deleted'
          ORDER BY b.updated_at DESC, b.bot_id DESC
          LIMIT $2 OFFSET $3
          """,
          [owner_user_id, limit, offset],
          type: true
        )
      )

    list_result(rows, limit, offset)
  end

  def list_admin(opts \\ %{}) do
    limit = parse_limit(opt(opts, :limit), 50)
    offset = decode_offset_cursor(opt(opts, :cursor))
    q = (opt(opts, :q) || "") |> String.trim() |> String.downcase()
    owner_user_id = opt(opts, :owner_user_id) || ""
    status = opt(opts, :status) || ""
    visibility = opt(opts, :visibility) || ""

    rows =
      Query.rows(
        Repo.query(
          """
          SELECT b.bot_id, b.owner_user_id, b.display_name, b.avatar_url, b.description,
                 b.visibility, b.status, b.created_at, b.updated_at,
                 (SELECT COUNT(*) FROM chat_v2.bot_commands c
                   WHERE c.bot_id = b.bot_id AND c.status = 'active' AND c.deleted_at IS NULL)
                   AS command_count
          FROM chat_v2.bot_apps b
          WHERE b.status != 'deleted'
            AND ($1 = '' OR lower(b.display_name) LIKE '%' || $1 || '%')
            AND ($2 = '' OR b.owner_user_id = $2)
            AND ($3 = '' OR b.status = $3)
            AND ($4 = '' OR b.visibility = $4)
          ORDER BY b.updated_at DESC, b.bot_id DESC
          LIMIT $5 OFFSET $6
          """,
          [q, owner_user_id, status, visibility, limit, offset],
          type: true
        )
      )

    list_result(rows, limit, offset)
  end

  defp list_result(rows, limit, offset) do
    {:ok,
     %{
       items: Enum.map(rows, &project_bot_with_count/1),
       next_cursor: next_cursor(rows, limit, offset)
     }}
  end

  defp next_cursor(rows, limit, offset) do
    if length(rows) == limit do
      encode_offset_cursor(offset + length(rows))
    else
      nil
    end
  end

  # --------------------------------------------------------------------------
  # get / update
  # --------------------------------------------------------------------------

  def get(bot_id) do
    case get_row(bot_id) do
      nil -> {:error, Errors.new("BOT_NOT_FOUND", "bot not found")}
      row -> {:ok, %{bot: project_bot(row)}}
    end
  end

  @doc """
  Partial bot update. `changes` is a list of `{field, value}` pairs (only the
  present fields); fields not in the known set are ignored. Validation order
  matches the old Worker: field validation, then the not-deleted existence
  check, then the UPDATE (updated_at always bumped).
  """
  def update(bot_id, changes) do
    values = Map.new(changes)

    present =
      for field <- ["display_name", "avatar_url", "description", "visibility", "status"],
          Map.has_key?(values, field),
          do: field

    if present == [] do
      {:error, Errors.new("INVALID_MESSAGE", "at least one field required")}
    else
      case validate_update_fields(values) do
        :ok ->
          do_update(bot_id, present, values)

        {:error, _} = err ->
          err
      end
    end
  end

  defp validate_update_fields(values) do
    cond do
      Map.has_key?(values, "display_name") and
          not (is_binary(values["display_name"]) and String.trim(values["display_name"]) != "") ->
        {:error, Errors.new("INVALID_MESSAGE", "display_name invalid")}

      Map.has_key?(values, "avatar_url") and
          not (is_nil(values["avatar_url"]) or is_binary(values["avatar_url"])) ->
        {:error, Errors.new("INVALID_MESSAGE", "avatar_url invalid")}

      Map.has_key?(values, "description") and
          not (is_nil(values["description"]) or is_binary(values["description"])) ->
        {:error, Errors.new("INVALID_MESSAGE", "description invalid")}

      Map.has_key?(values, "visibility") and values["visibility"] not in @visibilities ->
        {:error, Errors.new("INVALID_MESSAGE", "visibility invalid")}

      Map.has_key?(values, "status") and values["status"] not in @statuses ->
        {:error, Errors.new("INVALID_MESSAGE", "status invalid")}

      true ->
        :ok
    end
  end

  defp do_update(bot_id, fields, values) do
    row = get_row(bot_id)
    status = row && Map.get(row, "status")

    if is_nil(row) or status == "deleted" do
      {:error, Errors.new("BOT_NOT_FOUND", "bot not found")}
    else
      set_clause =
        fields
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {field, i} -> "#{field} = $" <> Integer.to_string(i + 1) end)

      sql =
        "UPDATE chat_v2.bot_apps SET updated_at = $" <>
          Integer.to_string(length(fields) + 1) <>
          ", " <>
          set_clause <>
          " WHERE bot_id = $" <>
          Integer.to_string(length(fields) + 2)

      params = Enum.map(fields, &values[&1]) ++ [DateTime.utc_now(), bot_id]

      Repo.query!(sql, params, type: true)
      {:ok, %{bot: project_bot(get_row(bot_id))}}
    end
  end

  # --------------------------------------------------------------------------
  # tokens
  # --------------------------------------------------------------------------

  def list_tokens(bot_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT token_id, name, scopes, created_at, expires_at, last_used_at, revoked_at
          FROM chat_v2.bot_tokens
          WHERE bot_id = $1
          ORDER BY created_at DESC, token_id DESC
          """,
          [bot_id],
          type: true
        )
      )

    {:ok,
     %{
       items:
         Enum.map(rows, fn row ->
           %{
             "token_id" => row["token_id"],
             "name" => row["name"],
             "scopes" => BotTokens.scopes_from_stored(row["scopes"]),
             "created_at" => Projections.format_ts(row["created_at"]),
             "expires_at" => Projections.format_ts(row["expires_at"]),
             "last_used_at" => Projections.format_ts(row["last_used_at"]),
             "revoked_at" => Projections.format_ts(row["revoked_at"])
           }
         end)
     }}
  end

  def create_token(bot_id, attrs) do
    name = attr(attrs, :name)

    unless is_binary(name) and String.trim(name) != "" do
      {:error, Errors.new("INVALID_MESSAGE", "token name required")}
    else
      unless bot_exists?(bot_id) do
        {:error, Errors.new("BOT_NOT_FOUND", "bot not found")}
      else
        name = String.trim(name)
        scopes = resolve_scopes(attrs[:scopes] || attrs["scopes"])
        plaintext = BotTokens.generate_plaintext()
        token_id = Ids.uuidv7()
        now = DateTime.utc_now()
        expires = attr(attrs, :expires_at)

        Repo.query!(
          """
          INSERT INTO chat_v2.bot_tokens
            (token_id, bot_id, name, token_hash, scopes, created_at, expires_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7)
          """,
          [
            token_id,
            bot_id,
            name,
            BotTokens.hash(plaintext),
            BotTokens.scopes_json(scopes),
            now,
            expires
          ]
        )

        {:ok,
         %{
           token: %{
             token_id: token_id,
             name: name,
             scopes: scopes,
             plaintext: plaintext,
             created_at: Projections.format_ts(now),
             expires_at: Projections.format_ts(expires)
           }
         }}
      end
    end
  end

  def revoke_token(bot_id, token_id) do
    rows =
      Query.rows(
        Repo.query(
          "SELECT revoked_at FROM chat_v2.bot_tokens WHERE token_id = $1 AND bot_id = $2",
          [token_id, bot_id],
          type: true
        )
      )

    case List.first(rows) do
      nil ->
        {:error, Errors.new("BOT_TOKEN_INVALID", "token not found")}

      row ->
        revoked_at = row["revoked_at"] || DateTime.utc_now()

        if row["revoked_at"] == nil do
          Repo.query!(
            "UPDATE chat_v2.bot_tokens SET revoked_at = $1 WHERE token_id = $2 AND bot_id = $3",
            [revoked_at, token_id, bot_id]
          )
        end

        {:ok, %{token_id: token_id, revoked_at: Projections.format_ts(revoked_at)}}
    end
  end

  # --------------------------------------------------------------------------
  # helpers
  # --------------------------------------------------------------------------

  defp bot_exists?(bot_id) do
    Query.rows(Repo.query("SELECT bot_id FROM chat_v2.bot_apps WHERE bot_id = $1", [bot_id]))
    |> length() > 0
  end

  defp get_row(bot_id) do
    Query.rows(
      Repo.query(
        """
        SELECT bot_id, owner_user_id, display_name, avatar_url, description,
               visibility, status, created_at, updated_at
        FROM chat_v2.bot_apps WHERE bot_id = $1
        """,
        [bot_id],
        type: true
      )
    )
    |> List.first()
  end

  # attr lookup tolerant of atom/string keys
  defp attr(attrs, key) do
    # Use has_key? so an explicit `false`/`nil` value is not dropped by `||`.
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, to_string(key)) -> Map.get(attrs, to_string(key))
      true -> nil
    end
  end

  defp attr_or_default(attrs, key, default) do
    case attr(attrs, key) do
      nil -> default
      v when is_binary(v) -> if String.trim(v) == "", do: default, else: String.trim(v)
      _ -> default
    end
  end

  defp fetch_bool(attrs, key, default) do
    case attr(attrs, key) do
      b when is_boolean(b) -> b
      _ -> default
    end
  end

  # A token's scopes: the request's list (filtered to non-empty strings) when
  # given, otherwise the default scopes (parity with the old Worker).
  defp resolve_scopes(raw) do
    case raw do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> BotTokens.default_scopes()
    end
  end

  defp opt(opts, key) do
    Map.get(opts, key) || Map.get(opts, to_string(key))
  end
end
