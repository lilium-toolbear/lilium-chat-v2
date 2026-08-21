defmodule LiliumChat.Observability.ReadPathTest do
  @moduledoc """
  Tests for the "reads are strictly read-only" assertion surface
  (spec §4 / A12 / §7.5, issue #3) — the tool conformance-differential and
  code review use to prove a read path executes no hidden writes.
  """

  use LiliumChat.DataCase, async: true

  alias LiliumChat.Observability.ReadPath

  test "run/1 returns the statement counts of a mixed function" do
    {_result, stats} =
      ReadPath.run(fn ->
        Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [])
        insert_channel()
      end)

    assert stats == %{reads: 1, writes: 1}
  end

  test "assert_read_only!/2 passes for a read-only function" do
    assert {:ok, %{reads: reads, writes: 0}} =
             ReadPath.assert_read_only!(fn -> Ecto.Adapters.SQL.query!(Repo, "SELECT 1", []) end)

    assert reads == 1
  end

  test "assert_read_only!/2 raises WriteError naming the context when a write sneaks in" do
    error =
      assert_raise(
        ReadPath.WriteError,
        ~r/1 write statement\(s\).*GET \/api\/chat\/channels/,
        fn ->
          ReadPath.assert_read_only!(fn -> insert_channel() end, "GET /api/chat/channels")
        end
      )

    assert error.writes == 1
    assert error.reads == 0
    assert error.context == "GET /api/chat/channels"
  end

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
