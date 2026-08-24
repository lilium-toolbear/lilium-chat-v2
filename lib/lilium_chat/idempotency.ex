defmodule LiliumChat.Idempotency do
  @moduledoc """
  Principal-scoped idempotency (contract §2.5 / spec D10, issue #16).

  The `user_command` namespace of the unified `chat_v2.idempotency` table,
  keyed by `(principal_kind, principal_id, operation, operation_id)`. The
  same key + same `request_hash` replays the stored ack payload; the same
  key + different `request_hash` is `IDEMPOTENCY_CONFLICT`. Rows expire after
  24h.

  `operation_id` is the transport-level `Idempotency-Key` header (HTTP).
  Principal kinds in use: `"user"` (browser JWT mutations) and `"bot"`
  (bot-token mutations).
  """

  alias LiliumChat.{Errors, Query, Repo}

  @ttl_ms 86_400_000

  @doc """
  Look up the stored record for an operation id.

  Returns:

  * `:missing` — no live row; run the mutation and `write_completed/6`.
  * `{:cached, response}` — same key + same request hash; replay `response`.
  * `{:conflict, %LiliumChat.Errors.ApiError{}}` — key reused with a
    different request body.
  """
  def check(principal_kind, principal_id, operation, operation_id, request_hash) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT request_hash, response_json
          FROM chat_v2.idempotency
          WHERE namespace = 'user_command'
            AND principal_kind = $1
            AND principal_id = $2
            AND operation = $3
            AND operation_id = $4
            AND (expires_at IS NULL OR expires_at > now())
          """,
          [principal_kind, principal_id, operation, operation_id],
          type: true
        )
      )

    case List.first(rows) do
      nil ->
        :missing

      row ->
        if row["request_hash"] == request_hash do
          {:cached, row["response_json"]}
        else
          {:conflict,
           Errors.new(
             "IDEMPOTENCY_CONFLICT",
             "idempotency key reused with different request body"
           )}
        end
    end
  end

  @doc """
  Run an idempotent command in ONE PG transaction: `check/5` → the caller's
  mutation (`fun` returns the ack payload) → `write_completed/6`.

  Cached replays return the stored response without calling `fun`; a key
  conflict raises before `fun` runs. An exception out of `fun` propagates
  (rolling the transaction back, so a failed command may be retried with
  the same key — the idempotency row is written only on success).
  """
  def run_operation(principal_kind, principal_id, operation, operation_id, request_hash, fun) do
    {:ok, response} =
      Repo.transaction(fn ->
        case check(principal_kind, principal_id, operation, operation_id, request_hash) do
          {:cached, response} ->
            response

          {:conflict, api_error} ->
            raise api_error

          :missing ->
            response = fun.()

            write_completed(
              principal_kind,
              principal_id,
              operation,
              operation_id,
              request_hash,
              response
            )

            response
        end
      end)

    response
  end

  @doc """
  Writer-op idempotency transaction (D10/D11, issue #13). `fun` returns the
  writer's tagged result payload (`%{kind: _, response: _, event_frames: _,
  user_hints: _, seq: _}`); the payload's `:response` is recorded via
  `write_completed/6` in the same transaction.

  Returns `{:ok, tagged_payload}` (fresh commit or cached replay — replays
  are rebuilt as `%{kind: :cached, response: response}`) or
  `{:error, %LiliumChat.Errors.ApiError{}}` (key conflict, or a
  `Repo.rollback(%{kind: :error, error: ...})` business gate from `fun`).
  Exceptions out of `fun` propagate (rolling the transaction back).
  """
  def run_writer_operation(
        principal_kind,
        principal_id,
        operation,
        operation_id,
        request_hash,
        fun
      ) do
    case Repo.transaction(fn ->
           case check(principal_kind, principal_id, operation, operation_id, request_hash) do
             {:conflict, api_error} ->
               Repo.rollback(api_error)

             {:cached, response} ->
               %{kind: :cached, response: response}

             :missing ->
               payload = fun.()

               write_completed(
                 principal_kind,
                 principal_id,
                 operation,
                 operation_id,
                 request_hash,
                 payload[:response]
               )

               payload
           end
         end) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, %Errors.ApiError{} = api_error} ->
        {:error, api_error}

      {:error, %{kind: :error, error: api_error}} ->
        {:error, api_error}
    end
  end

  @doc """
  Store the committed ack payload for an operation id. Must run in the same
  transaction as the business mutation (contract §2.5).
  """
  def write_completed(
        principal_kind,
        principal_id,
        operation,
        operation_id,
        request_hash,
        response
      ) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, @ttl_ms, :millisecond)

    # The `id` column is a PG `uuid` (:binary_id) — Postgrex wants the 16-byte
    # binary form, not the hyphenated string.
    id = Ecto.UUID.bingenerate()

    Repo.query!(
      """
      INSERT INTO chat_v2.idempotency
        (id, namespace, principal_kind, principal_id, operation, operation_id,
         status, request_hash, response_json, created_at, updated_at, expires_at)
      VALUES ($1, 'user_command', $2, $3, $4, $5, 'completed', $6, $7, $8, $8, $9)
      """,
      [
        id,
        principal_kind,
        principal_id,
        operation,
        operation_id,
        request_hash,
        response,
        now,
        expires
      ],
      type: true
    )
  end
end
