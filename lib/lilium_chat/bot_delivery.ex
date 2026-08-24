defmodule LiliumChat.BotDelivery do
  @moduledoc """
  Bot delivery commit + result pipeline (contract §9.7 / spec D14,
  issue #17).

  Deliveries are the at-least-once handoff from the server to a Bot:

  1. **Commit** — `commit_invocation/1` / `commit_interaction/1` /
     `commit_message_event/1` persist a business row (if any) plus a
     `bot_deliveries` row (`status = 'pending'`) in one PG transaction,
     then push the `delivery` frame if the bot is online.
  2. **Resume** — on (re)connect the `Bot.<bot_id>` process redelivers every
     `pending` row in `delivery_id` order (UUIDv7 = chronological); the bot
     dedupes on `delivery_id`.
  3. **Complete** — a `delivery_result` runs `apply_result/3`: effects are
     applied idempotently (`LiliumChat.BotEffects`), the row becomes
     `delivered`, and the business row (invocation / interaction) becomes
     `completed`. The bot is acked with `delivery_ack`.
  4. **Drop** — terminal `dropped`: offline short-TTL expiry
     (`expire_offline/1`) or max attempts. Invocation/interaction rows then
     flip to `failed` (`BOT_OFFLINE`); `message_event` drops silently
     (passive, no user-visible error).

  Offline policy (contract §9.7):

    * `command_invocation` / `message_interaction` — precheck: bot offline →
      `BOT_OFFLINE` **before** the invocation/interaction row is persisted
      (AC2). Committed but bot gone → short TTL, then `failed`.
    * `message_event` — passive: committed rows are dropped after their TTL
      (no user-visible error, no bulk replay of history).
  """

  alias LiliumChat.{
    BotEffects,
    BotGateway,
    BotConnection,
    Channel,
    Errors,
    Ids,
    Projections,
    Profiles,
    Query,
    Repo
  }

  @doc """
  Commit a `command_invocation` delivery (contract §9.7.1).

  `attrs`: `:channel_id`, `:bot_id`, `:invoker_user_id`, `:bot_command_id`,
  `:command_name`, `:invoked_name`, `:schema_version`, `:definition_hash`,
  `:options` (map), `:command_id` (the durable operation id), optional
  `:invocation_id` (generated when absent).

  Returns `{:ok, %{delivery_id, invocation_id}}` or
  `{:error, %Errors.ApiError{}}` — on `BOT_OFFLINE` nothing is persisted.
  """
  def commit_invocation(attrs) do
    invoker =
      Projections.user_summary(
        attrs[:invoker_user_id],
        Profiles.resolve([attrs[:invoker_user_id]])
      )

    invocation_id = attrs[:invocation_id] || Ids.uuidv7()

    with :ok <- precheck_online(attrs[:bot_id]) do
      delivery_id = Ids.uuidv7()
      now = DateTime.utc_now()

      body = %{
        "invocation_id" => invocation_id,
        "command" => %{
          "bot_command_id" => attrs[:bot_command_id],
          "name" => attrs[:command_name],
          "invoked_name" => attrs[:invoked_name],
          "schema_version" => attrs[:schema_version],
          "definition_hash" => attrs[:definition_hash],
          "options" => attrs[:options] || %{}
        },
        "invoker" => invoker
      }

      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO chat_v2.command_invocations
              (invocation_id, channel_id, command_id, invoker_user_id, bot_id,
               bot_command_id, command_name, invoked_name, command_schema_version,
               command_definition_hash, options_json, status, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'pending', $12, $12)
            """,
            [
              invocation_id,
              attrs[:channel_id],
              attrs[:command_id] || Ids.uuidv7(),
              attrs[:invoker_user_id],
              attrs[:bot_id],
              attrs[:bot_command_id],
              attrs[:command_name],
              attrs[:invoked_name],
              attrs[:schema_version],
              attrs[:definition_hash],
              attrs[:options] || %{},
              now
            ],
            type: true
          )

          insert_delivery(
            delivery_id,
            attrs[:channel_id],
            attrs[:bot_id],
            "command_invocation",
            body,
            invocation_id,
            nil,
            nil,
            now
          )
        end)

      push_if_online(
        attrs[:bot_id],
        delivery_frame(delivery_id, attrs[:channel_id], "command_invocation", body)
      )

      {:ok, %{delivery_id: delivery_id, invocation_id: invocation_id}}
    end
  end

  @doc """
  Commit a `message_interaction` delivery (contract §9.7.1).

  `attrs`: `:channel_id`, `:bot_id`, `:actor_user_id`, `:message_id`,
  `:component_id`, `:custom_id`, `:value`, `:command_id`,
  `:dedupe_principal_key`, optional `:interaction_id` and `:pin_id`
  (pin-locator interactions — the delivery body then carries `pin_id`
  instead of `message_id`, old Worker parity; the `interactions` row
  stores the pin id in `message_id`).

  Returns `{:ok, %{delivery_id, interaction_id}}` or
  `{:error, %Errors.ApiError{}}` — on `BOT_OFFLINE` nothing is persisted.
  """
  def commit_interaction(attrs) do
    actor =
      Projections.user_summary(attrs[:actor_user_id], Profiles.resolve([attrs[:actor_user_id]]))

    interaction_id = attrs[:interaction_id] || Ids.uuidv7()

    with :ok <- precheck_online(attrs[:bot_id]) do
      delivery_id = Ids.uuidv7()
      now = DateTime.utc_now()

      body = %{
        "interaction_id" => interaction_id,
        "component" => %{
          "component_id" => attrs[:component_id],
          "custom_id" => attrs[:custom_id],
          "value" => attrs[:value]
        },
        "actor" => actor
      }

      body =
        if attrs[:pin_id] do
          Map.put(body, "pin_id", attrs[:pin_id])
        else
          Map.put(body, "message_id", attrs[:message_id])
        end

      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO chat_v2.interactions
              (interaction_id, message_id, pin_id, component_id, custom_id, actor_user_id,
               dedupe_principal_key, command_id, value_json, status, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'pending', $10, $10)
            """,
            [
              interaction_id,
              attrs[:message_id],
              attrs[:pin_id],
              attrs[:component_id],
              attrs[:custom_id],
              attrs[:actor_user_id],
              attrs[:dedupe_principal_key],
              attrs[:command_id],
              attrs[:value],
              now
            ],
            type: true
          )

          insert_delivery(
            delivery_id,
            attrs[:channel_id],
            attrs[:bot_id],
            "message_interaction",
            body,
            nil,
            interaction_id,
            nil,
            now
          )
        end)

      push_if_online(
        attrs[:bot_id],
        delivery_frame(delivery_id, attrs[:channel_id], "message_interaction", body)
      )

      {:ok, %{delivery_id: delivery_id, interaction_id: interaction_id}}
    end
  end

  @doc """
  Commit a `message_event` delivery (contract §9.7.1). **Passive** kind:
  always returns `{:ok, %{delivery_id}}` (no error to the caller); when the
  bot is offline the row stays `pending` and is dropped after its TTL
  (`expire_offline/1`) — no user-visible error, no bulk replay.

  `attrs`: `:channel_id`, `:bot_id`, `:event_id` (optional, generated),
  `:event_type` (default `"message.created"`), `:occurred_at` (default now),
  `:message` — the full Browser-visible message projection (sender included).
  """
  def commit_message_event(attrs) do
    event_id = attrs[:event_id] || Ids.uuidv7()
    occurred_at = attrs[:occurred_at] || DateTime.utc_now()

    delivery_id = Ids.uuidv7()
    now = DateTime.utc_now()

    body = %{
      "event" => %{
        "event_id" => event_id,
        "type" => attrs[:event_type] || "message.created",
        "occurred_at" => iso(occurred_at)
      },
      "message" => attrs[:message] || %{}
    }

    Repo.query!(
      """
      INSERT INTO chat_v2.bot_deliveries
        (delivery_id, channel_id, bot_id, kind, invocation_id, interaction_id,
         event_id, request_json, status, attempts, max_attempts, created_at, updated_at)
      VALUES ($1, $2, $3, 'message_event', NULL, NULL, $4, $5, 'pending', 0, 5, $6, $6)
      """,
      [
        delivery_id,
        attrs[:channel_id],
        attrs[:bot_id],
        event_id,
        body,
        now
      ],
      type: true
    )

    push_if_online(
      attrs[:bot_id],
      delivery_frame(delivery_id, attrs[:channel_id], "message_event", body)
    )

    {:ok, %{delivery_id: delivery_id}}
  end

  # ------------------------------------------------------------------ result

  @doc """
  Process a bot `delivery_result` (contract §9.7). Called by the
  `Bot.<bot_id>` process.

  Returns the `delivery_ack` frame (map). The whole effect batch applies on
  the per-channel writer (`LiliumChat.Channel`) in ONE PG transaction with
  `(channel_id, bot_id, client_effect_id)` idempotency (old Worker
  `applyValidatedEffects` parity — a `BOT_EFFECT_CONFLICT` anywhere in the
  batch rolls the batch back); a duplicate `delivery_result`
  (at-least-once replay) re-runs the pipeline and the idempotency rows
  replay the stored results — the ack is identical. Post-commit, the
  writer's finalize step enqueues listen inputs + live stream frames.
  """
  def apply_result(bot_id, delivery_id, effects) do
    case load_delivery(bot_id, delivery_id) do
      nil ->
        ack_failed(delivery_id, "BOT_EFFECT_INVALID", "unknown delivery_id")

      row ->
        channel_id = row["channel_id"]
        is_official = BotEffects.bot_official?(bot_id)

        case BotEffects.validate(effects, is_official: is_official) do
          {:error, %Errors.ApiError{} = api_error} ->
            finalize_interaction_failed(row, api_error)
            finalize_failed(row, api_error)
            ack_failed(delivery_id, api_error.code, api_error.message)

          {:ok, _} ->
            # The delivery_result path never touches the session_control pin
            # (that is the session.effects allowlist, contract §9.7.3). A
            # `message_interaction` delivery also finalizes the interaction
            # lifecycle on the writer (issue #20).
            case Channel.apply_bot_effects(channel_id, %{
                   bot_id: bot_id,
                   effects: effects,
                   is_official: is_official,
                   allow_session_control: false,
                   delivery: row
                 }) do
              {:ok, %{effect_results: results}} ->
                finalize_delivered(row)

                BotGateway.build_delivery_ack(
                  delivery_id,
                  "applied",
                  %{"effect_results" => results}
                )

              {:error, %Errors.ApiError{} = api_error} ->
                finalize_interaction_failed(row, api_error)
                finalize_failed(row, api_error)
                ack_failed(delivery_id, api_error.code, api_error.message)
            end
        end
    end
  end

  # A failed `message_interaction` delivery emits `interaction.failed` on
  # the channel writer (issue #20, old Worker `finalizeInteractionDelivery`).
  defp finalize_interaction_failed(%{"kind" => "message_interaction"} = row, api_error) do
    Channel.finalize_interaction(row["channel_id"], %{
      interaction_id: row["interaction_id"],
      bot_id: row["bot_id"],
      success: false,
      error_code: api_error.code,
      error_message: api_error.message
    })

    :ok
  end

  defp finalize_interaction_failed(_row, _api_error), do: :ok

  # ------------------------------------------------------------- offline TTL

  @doc """
  Expire a bot's `pending` deliveries after the offline short TTL
  (contract §9.7 offline policy). Called by the `Bot.<bot_id>` process timer
  `offline_ttl_ms` after the connection goes away.

  * `command_invocation` / `message_interaction` rows → `dropped` + the
    business row flips to `failed` (`BOT_OFFLINE`).
  * `message_event` rows → `dropped` once their own TTL has elapsed
    (passive; still-young rows stay pending for a possible resume).

  Returns the number of rows dropped.
  """
  def expire_offline(bot_id) do
    event_ttl = config(:message_event_ttl_ms, 30_000)
    now = DateTime.utc_now()

    rows =
      Query.rows(
        Repo.query(
          """
          SELECT delivery_id, kind, invocation_id, interaction_id, created_at
          FROM chat_v2.bot_deliveries
          WHERE bot_id = $1 AND status = 'pending'
          ORDER BY delivery_id
          """,
          [bot_id],
          type: true
        )
      )

    dropped =
      rows
      |> Enum.filter(fn row ->
        case row["kind"] do
          "message_event" -> elapsed_since(row["created_at"], event_ttl, now)
          _ -> true
        end
      end)
      |> Enum.map(fn row ->
        Repo.query!(
          """
          UPDATE chat_v2.bot_deliveries
          SET status = 'dropped', failed_at = $2, last_error = $3
          WHERE delivery_id = $1 AND status = 'pending'
          """,
          [row["delivery_id"], now, "offline expired"],
          type: true
        )

        case row["kind"] do
          "command_invocation" ->
            fail_business(
              "chat_v2.command_invocations",
              "invocation_id",
              row["invocation_id"],
              now
            )

          "message_interaction" ->
            # chat_v2.interactions has no error_message column (schema).
            fail_business(
              "chat_v2.interactions",
              "interaction_id",
              row["interaction_id"],
              now,
              Errors.new("BOT_OFFLINE"),
              false
            )

          _ ->
            :ok
        end
      end)

    length(dropped)
  end

  @doc "Count of the bot's `pending` deliveries (timer bookkeeping)."
  def pending_count(bot_id) do
    Query.rows(
      Repo.query(
        "SELECT count(*) AS n FROM chat_v2.bot_deliveries WHERE bot_id = $1 AND status = 'pending'",
        [bot_id],
        type: true
      )
    )
    |> List.first()
    |> Map.get("n")
  end

  # ----------------------------------------------------------------- frames

  @doc """
  Load a bot's `pending` deliveries as `delivery` frames, `delivery_id`
  order, and account the redelivery as an attempt (at-least-once, spec D14).

  Max-attempts enforcement (old Worker `bumpDeliveryRetry` parity): when a
  row's attempt count reaches its `max_attempts`, the row is dropped
  (`last_error: "max_attempts"`) and the business row fails — the frame is
  still delivered on this pass (the bot gets the final attempt).
  """
  def resume_frames(bot_id) do
    now = DateTime.utc_now()

    rows =
      Query.rows(
        Repo.query(
          """
          SELECT delivery_id, kind, channel_id, request_json,
                 attempts, max_attempts, invocation_id, interaction_id
          FROM chat_v2.bot_deliveries
          WHERE bot_id = $1 AND status = 'pending'
          ORDER BY delivery_id
          """,
          [bot_id],
          type: true
        )
      )

    rows
    |> Enum.map(fn row -> Map.put(row, "now", now) end)
    |> Enum.map(fn row ->
      attempts = row["attempts"] + 1

      if attempts >= row["max_attempts"] do
        Repo.query!(
          """
          UPDATE chat_v2.bot_deliveries
          SET status = 'dropped', attempts = $2, last_error = 'max_attempts',
              failed_at = $3, updated_at = $3
          WHERE delivery_id = $1 AND status = 'pending'
          """,
          [row["delivery_id"], attempts, now],
          type: true
        )

        fail_business_for(row)
      else
        Repo.query!(
          """
          UPDATE chat_v2.bot_deliveries
          SET attempts = $2, updated_at = $3
          WHERE delivery_id = $1 AND status = 'pending'
          """,
          [row["delivery_id"], attempts, now],
          type: true
        )
      end

      BotGateway.build_delivery_frame(%{
        "delivery_id" => row["delivery_id"],
        "kind" => row["kind"],
        "channel_id" => row["channel_id"],
        "request_json" => row["request_json"]
      })
    end)
  end

  # `now` rides in the row map from `resume_frames/1` (single clock per
  # resume pass).
  defp fail_business_for(%{"kind" => "command_invocation"} = row) do
    fail_business(
      "chat_v2.command_invocations",
      "invocation_id",
      row["invocation_id"],
      row["now"]
    )
  end

  defp fail_business_for(%{"kind" => "message_interaction"} = row) do
    # chat_v2.interactions has no error_message column (schema). The
    # contract's only bot-side failure code is BOT_OFFLINE (the delivery
    # window elapsed while the bot was away).
    fail_business(
      "chat_v2.interactions",
      "interaction_id",
      row["interaction_id"],
      row["now"],
      Errors.new("BOT_OFFLINE"),
      false
    )
  end

  defp fail_business_for(_row), do: :ok

  # --------------------------------------------------------------- internals

  defp precheck_online(bot_id) do
    if BotConnection.online?(bot_id) do
      :ok
    else
      {:error, Errors.new("BOT_OFFLINE")}
    end
  end

  defp insert_delivery(
         delivery_id,
         channel_id,
         bot_id,
         kind,
         body,
         invocation_id,
         interaction_id,
         event_id,
         now
       ) do
    # max_attempts = 3: old Worker MAX_BOT_DELIVERY_ATTEMPTS parity.
    Repo.query!(
      """
      INSERT INTO chat_v2.bot_deliveries
        (delivery_id, channel_id, bot_id, kind, invocation_id, interaction_id,
         event_id, request_json, status, attempts, max_attempts, created_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'pending', 0, 3, $9, $9)
      """,
      [delivery_id, channel_id, bot_id, kind, invocation_id, interaction_id, event_id, body, now],
      type: true
    )
  end

  defp delivery_frame(delivery_id, channel_id, kind, body) do
    BotGateway.build_delivery_frame(%{
      "delivery_id" => delivery_id,
      "kind" => kind,
      "channel_id" => channel_id,
      "request_json" => body
    })
  end

  # Best-effort push: when the bot is offline the row simply stays pending
  # and resume redelivers it (at-least-once).
  defp push_if_online(bot_id, frame) do
    BotConnection.push_frame(bot_id, frame)
    :ok
  end

  defp ack_failed(delivery_id, code, message) do
    BotGateway.build_delivery_ack(delivery_id, "failed", %{
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp load_delivery(bot_id, delivery_id) do
    Query.rows(
      Repo.query(
        """
        SELECT delivery_id, channel_id, bot_id, kind, invocation_id, interaction_id, status
        FROM chat_v2.bot_deliveries
        WHERE delivery_id = $1 AND bot_id = $2
        """,
        [delivery_id, bot_id],
        type: true
      )
    )
    |> List.first()
  end

  defp finalize_delivered(%{"kind" => kind} = row) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      UPDATE chat_v2.bot_deliveries
      SET status = 'delivered', delivered_at = $2
      WHERE delivery_id = $1
      """,
      [row["delivery_id"], now],
      type: true
    )

    case kind do
      "command_invocation" ->
        Repo.query!(
          """
          UPDATE chat_v2.command_invocations
          SET status = 'completed', completed_at = $2, updated_at = $2
          WHERE invocation_id = $1
          """,
          [row["invocation_id"], now],
          type: true
        )

      "message_interaction" ->
        Repo.query!(
          """
          UPDATE chat_v2.interactions
          SET status = 'completed', completed_at = $2, updated_at = $2
          WHERE interaction_id = $1
          """,
          [row["interaction_id"], now],
          type: true
        )

      _ ->
        :ok
    end
  end

  defp finalize_failed(%{"kind" => kind} = row, %Errors.ApiError{} = api_error) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      UPDATE chat_v2.bot_deliveries
      SET status = 'dropped', failed_at = $2, last_error = $3
      WHERE delivery_id = $1
      """,
      [row["delivery_id"], now, "#{api_error.code}: #{api_error.message}"],
      type: true
    )

    case kind do
      "command_invocation" ->
        fail_business(
          "chat_v2.command_invocations",
          "invocation_id",
          row["invocation_id"],
          now,
          api_error,
          true
        )

      "message_interaction" ->
        # chat_v2.interactions has no error_message column (schema).
        fail_business(
          "chat_v2.interactions",
          "interaction_id",
          row["interaction_id"],
          now,
          api_error,
          false
        )

      _ ->
        :ok
    end
  end

  # `with_message`: command_invocations stores error_message; interactions
  # only has error_code.
  defp fail_business(
         table,
         column,
         id,
         now,
         api_error \\ Errors.new("BOT_OFFLINE"),
         with_message \\ true
       ) do
    if is_binary(id) do
      {set_sql, params} =
        if with_message do
          {
            "status = 'failed', error_code = $3, error_message = $4, updated_at = $2",
            [id, now, api_error.code, api_error.message]
          }
        else
          {
            "status = 'failed', error_code = $3, updated_at = $2",
            [id, now, api_error.code]
          }
        end

      Repo.query!(
        "UPDATE #{table} SET #{set_sql} WHERE #{column} = $1",
        params,
        type: true
      )
    end
  end

  # The row's TTL has elapsed (created_at + ttl <= now) → eligible to drop.
  defp elapsed_since(created_at, ttl_ms, now) do
    case created_at do
      %NaiveDateTime{} = c ->
        NaiveDateTime.compare(NaiveDateTime.add(c, ttl_ms, :millisecond), DateTime.to_naive(now)) in [
          :lt,
          :eq
        ]

      %DateTime{} = c ->
        DateTime.compare(DateTime.add(c, ttl_ms, :millisecond), now) in [:lt, :eq]

      _ ->
        true
    end
  end

  defp iso(value) when is_struct(value, DateTime), do: DateTime.to_iso8601(value)
  defp iso(value) when is_struct(value, NaiveDateTime), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso(value), do: value

  defp config(key, default) do
    Application.get_env(:lilium_chat, :bot_gateway, [])
    |> Keyword.get(key, default)
  end
end
