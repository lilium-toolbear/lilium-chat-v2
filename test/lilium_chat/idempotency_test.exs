defmodule LiliumChat.IdempotencyTest do
  @moduledoc """
  `LiliumChat.Idempotency` unit tests (issue #23).

  Regression: `check/5` filters reads with `expires_at > now()`, so an
  expired-but-not-yet-GC'd row is invisible to `check/5` while still holding
  the per-namespace unique key. The plain `INSERT` in `write_completed/6`
  then collided with the partial unique index (`uniq_chat_v2_idem_user_command`)
  and raised a non-ApiError unique violation — crashing the per-channel writer
  and the Phoenix socket. `write_completed/6` must overwrite the expired
  leftover via `ON CONFLICT ... DO UPDATE` instead, without changing the
  stored replay/conflict error semantics.
  """

  use LiliumChat.DataCase, async: false

  alias LiliumChat.{Errors, Idempotency, Ids, Query, Repo}

  @principal_kind "user"
  @principal_id "idem-unit-test-user"
  @operation "test.ping"

  # ----------------------------------------------------------------- helpers

  # Seed a row exactly as `write_completed/6` persists it, but with a
  # caller-chosen `created_at` / `expires_at` (Housekeeping GC reaps the
  # expired ones in production).
  defp seed_row!(operation_id, request_hash, response, created_at, expires_at) do
    id = Ids.uuid_bytes(Ids.uuidv7())
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.idempotency
        (id, namespace, principal_kind, principal_id, operation, operation_id,
         status, request_hash, response_json, created_at, updated_at, expires_at)
      VALUES ($1, 'user_command', $2, $3, $4, $5, 'completed', $6, $7, $8, $9, $10)
      """,
      [
        id,
        @principal_kind,
        @principal_id,
        @operation,
        operation_id,
        request_hash,
        response,
        created_at,
        now,
        expires_at
      ],
      type: true
    )

    id
  end

  defp row(operation_id) do
    Query.rows(
      Repo.query(
        """
        SELECT id, status, request_hash, response_json, created_at, updated_at, expires_at
        FROM chat_v2.idempotency
        WHERE namespace = 'user_command'
          AND principal_kind = $1 AND principal_id = $2
          AND operation = $3 AND operation_id = $4
        """,
        [@principal_kind, @principal_id, @operation, operation_id],
        type: true
      )
    )
    |> hd()
  end

  defp row_count(operation_id) do
    case Repo.query(
           "SELECT COUNT(*) AS n FROM chat_v2.idempotency " <>
             "WHERE namespace = 'user_command' AND principal_kind = $1 " <>
             "AND principal_id = $2 AND operation = $3 AND operation_id = $4",
           [@principal_kind, @principal_id, @operation, operation_id]
         ) do
      {:ok, %{rows: [[n]]}} -> n
    end
  end

  # `expires_at` / `created_at` columns decode as `NaiveDateTime` in tests.
  defp expired!(offset_seconds \\ -3600),
    do: NaiveDateTime.add(NaiveDateTime.utc_now(), offset_seconds, :second)

  defp fresh_writer(payload_response) do
    fn ->
      %{kind: :fresh, response: payload_response, event_frames: [], user_hints: [], seq: 1}
    end
  end

  # ------------------------------------- AC1: no UniqueConstraintError on replay

  test "write_completed/6 overwrites an expired leftover row instead of raising UniqueConstraintError" do
    key = "idem-direct-overwrite"
    stale_created = NaiveDateTime.add(NaiveDateTime.utc_now(), -2, :hour)
    fresh = %{"message_id" => "msg-fresh"}

    seed_row!(key, "hash-stale", %{"message_id" => "msg-stale"}, stale_created, expired!())

    # Pre-fix (issue #23) this plain INSERT collided with the partial unique
    # index and raised a Postgrex unique violation — a non-ApiError crash in
    # the per-channel writer.
    Idempotency.write_completed(
      @principal_kind,
      @principal_id,
      @operation,
      key,
      "hash-fresh",
      fresh
    )

    assert row_count(key) == 1
    assert row(key)["request_hash"] == "hash-fresh"
    assert row(key)["response_json"] == fresh
    assert row(key)["status"] == "completed"

    # The leftover is updated IN PLACE: first-seen `created_at` is preserved,
    # and the TTL is refreshed into the future. (Use semantic
    # `NaiveDateTime.compare/2` — Elixir's `>` on structs is structural,
    # not chronological.)
    assert NaiveDateTime.diff(row(key)["created_at"], stale_created, :second) < 5
    assert NaiveDateTime.compare(row(key)["expires_at"], NaiveDateTime.utc_now()) == :gt
  end

  test "write_completed/6 on a LIVE conflicting row leaves it untouched (concurrent-winner guard)" do
    key = "idem-live-guard"
    winner = %{"message_id" => "msg-winner"}

    # A live row (fresh expiry) that this write did not see: the DO UPDATE
    # guard must NOT clobber it — a concurrent same-key winner committed
    # between check/5 and the INSERT.
    seed_row!(key, "hash-winner", winner, NaiveDateTime.utc_now(), expired!(+86_400))

    Idempotency.write_completed(
      @principal_kind,
      @principal_id,
      @operation,
      key,
      "hash-loser",
      %{"message_id" => "msg-loser"}
    )

    assert row_count(key) == 1
    assert row(key)["request_hash"] == "hash-winner"
    assert row(key)["response_json"] == winner
  end

  # -------------------------- AC2: expired row + same-key replay, cached ack

  test "expired leftover + same key + same body → fresh write wins, then cached replay" do
    key = "idem-expired-replay"
    fresh = %{"message_id" => "msg-fresh"}

    # A completed operation left an expired row behind (GC has not reaped it).
    seed_row!(key, "hash-same", %{"message_id" => "msg-stale"}, expired!(-7200), expired!(-3600))

    # The expired row is invisible to `check/5` → the mutation re-runs and
    # `write_completed/6` must overwrite the leftover, not crash.
    assert {:ok, %{kind: :fresh, response: ^fresh}} =
             Idempotency.run_writer_operation(
               @principal_kind,
               @principal_id,
               @operation,
               key,
               "hash-same",
               fresh_writer(fresh)
             )

    assert row(key)["request_hash"] == "hash-same"
    assert row(key)["response_json"] == fresh

    # Same-key same-body replay now hits the freshly written row's cache.
    assert {:ok, %{kind: :cached, response: ^fresh}} =
             Idempotency.run_writer_operation(
               @principal_kind,
               @principal_id,
               @operation,
               key,
               "hash-same",
               fn -> raise "cached replay must not re-run the mutation" end
             )
  end

  # -------------------- AC2: expired row + same key, different body semantics

  test "expired leftover + same key + different body → fresh write overwrites, no conflict" do
    key = "idem-expired-diff-body"
    fresh = %{"message_id" => "msg-new"}

    seed_row!(key, "hash-old", %{"message_id" => "msg-old"}, expired!(-7200), expired!(-3600))

    # A different body against a DEAD row is a fresh operation (the row was
    # invisible to `check/5`), not a conflict.
    assert {:ok, %{kind: :fresh, response: ^fresh}} =
             Idempotency.run_writer_operation(
               @principal_kind,
               @principal_id,
               @operation,
               key,
               "hash-new",
               fresh_writer(fresh)
             )

    assert row(key)["request_hash"] == "hash-new"
    assert row(key)["response_json"] == fresh

    # The row is live again, so a third body now conflicts.
    assert {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
             Idempotency.run_writer_operation(
               @principal_kind,
               @principal_id,
               @operation,
               key,
               "hash-third",
               fn -> raise "conflict must short-circuit before the mutation" end
             )
  end

  test "run_operation/6 over an expired leftover row: fresh response, then cached replay" do
    key = "idem-run-operation"
    fresh = %{"sticker_id" => "st-fresh"}

    seed_row!(key, "hash-ro", %{"sticker_id" => "st-stale"}, expired!(-7200), expired!(-3600))

    # The `run_operation/6` path (stickers / bot command sync) shares the
    # same write_completed/6 fix.
    assert ^fresh =
             Idempotency.run_operation(
               @principal_kind,
               @principal_id,
               @operation,
               key,
               "hash-ro",
               fn -> fresh end
             )

    # Same-key replay hits the freshly written row's cache.
    assert ^fresh =
             Idempotency.run_operation(
               @principal_kind,
               @principal_id,
               @operation,
               key,
               "hash-ro",
               fn -> raise "cached replay must not re-run the mutation" end
             )
  end

  # ------------------------- AC2: IDEMPOTENCY_CONFLICT semantics unchanged

  test "live row + same key + different body → IDEMPOTENCY_CONFLICT (unchanged semantics)" do
    key = "idem-live-conflict"

    seed_row!(
      key,
      "hash-a",
      %{"message_id" => "msg-a"},
      NaiveDateTime.utc_now(),
      expired!(+86_400)
    )

    assert {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
             Idempotency.run_writer_operation(
               @principal_kind,
               @principal_id,
               @operation,
               key,
               "hash-b",
               fn -> raise "conflict must short-circuit before the mutation" end
             )

    # And the live row is untouched by the conflict.
    assert row(key)["request_hash"] == "hash-a"
    assert row(key)["response_json"] == %{"message_id" => "msg-a"}
  end
end
