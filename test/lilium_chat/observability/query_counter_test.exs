defmodule LiliumChat.Observability.QueryCounterTest do
  @moduledoc """
  Unit + integration tests for the per-process PG statement counter
  (spec §4 / A12 / §7.5, issue #3).
  """

  use LiliumChat.DataCase, async: true

  alias LiliumChat.Observability.QueryCounter

  describe "classify/1" do
    test "SELECT is a read" do
      assert QueryCounter.classify("SELECT * FROM chat_v2.channels") == :read
    end

    test "DML statements are writes" do
      for sql <- [
            "INSERT INTO chat_v2.channels (channel_id) VALUES ('c1') RETURNING channel_id",
            "UPDATE chat_v2.channels SET title = 'x' WHERE channel_id = 'c1'",
            "DELETE FROM chat_v2.channels WHERE channel_id = 'c1'"
          ] do
        assert QueryCounter.classify(sql) == :write
      end
    end

    test "CTEs are classified by their main clause" do
      assert QueryCounter.classify("WITH c AS (SELECT 1) SELECT * FROM c") == :read
      assert QueryCounter.classify("WITH c AS (SELECT 1) INSERT INTO t VALUES (1)") == :write
    end

    test "word-boundary matching avoids false positives on identifiers" do
      # 'updates' table and 'updated_at' column must not count as writes.
      assert QueryCounter.classify("SELECT updated_at FROM updates") == :read
    end
  end

  describe "with_counting/1 against a real Repo" do
    test "counts read and write statements separately" do
      {result, stats} =
        QueryCounter.with_counting(fn ->
          assert {:ok, %{rows: [[1]]}} = Ecto.Adapters.SQL.query(Repo, "SELECT 1", [])
          insert_channel()
          :done
        end)

      assert result == :done
      assert stats == %{reads: 1, writes: 1}
    end

    test "statements outside the window are not counted" do
      # Warm-up query with no window open — must be ignored.
      assert {:ok, %{rows: [[1]]}} = Ecto.Adapters.SQL.query(Repo, "SELECT 1", [])

      {_result, stats} = QueryCounter.with_counting(fn -> :ok end)
      assert stats == %{reads: 0, writes: 0}
    end

    test "closes the window and leaves no process-dict residue" do
      assert_raise RuntimeError, "boom", fn ->
        QueryCounter.with_counting(fn -> raise "boom" end)
      end

      refute QueryCounter.active?()
    end

    test "nested windows: inner totals merge into the outer one" do
      {outer_result, outer_stats} =
        QueryCounter.with_counting(fn ->
          assert {:ok, %{rows: [[1]]}} = Ecto.Adapters.SQL.query(Repo, "SELECT 1", [])

          {_inner_result, inner_stats} =
            QueryCounter.with_counting(fn ->
              insert_channel()
              :inner
            end)

          assert inner_stats == %{reads: 0, writes: 1}
          :outer
        end)

      assert outer_result == :outer
      # Outer window saw the SELECT plus the merged inner INSERT.
      assert outer_stats == %{reads: 1, writes: 1}
    end
  end

  # Sandbox (DataCase) rolls the INSERT back at test end — no cleanup query,
  # which would itself be counted.
  defp insert_channel do
    Repo.query!(
      """
      INSERT INTO chat_v2.channels
        (channel_id, kind, visibility, title, status, created_by, created_at, updated_at)
      VALUES ($1, 'group', 'private', 't', 'active', 'u1', now(), now())
      RETURNING channel_id
      """,
      ["ch_test_#{System.unique_integer([:positive])}"]
    )
  end
end
