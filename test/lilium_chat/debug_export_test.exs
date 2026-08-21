defmodule LiliumChat.DebugExportTest do
  @moduledoc """
  Wire-format tests for the old-Worker debug API client (issue #4, spec §8).

  A raw-HTTP stub (`LiliumChat.DebugStub`) answers `/internal/debug/sql-all`
  with production-shaped payloads; `LiliumChat.DebugExport` must map them to
  import-ready rows.
  """
  use ExUnit.Case, async: true

  alias LiliumChat.{DebugExport, DebugStub}

  defp start_stub!(handler) do
    {:ok, stub} = DebugStub.start_link(handler)
    on_exit(fn -> DebugStub.stop(stub) end)
    "http://127.0.0.1:#{stub.port}"
  end

  test "export_read_state maps instance names to user_id and flattens rows" do
    base =
      start_stub!(fn _path, _body ->
        {200,
         Jason.encode!(%{
           "class" => "UserDirectory",
           "instance_count" => 2,
           "results" => [
             %{
               "name" => "user-a",
               "ok" => true,
               "result" => %{
                 "columns" => ["channel_id", "last_read_event_id"],
                 "rows" => [
                   %{"channel_id" => "ch1", "last_read_event_id" => "ev-1"},
                   %{"channel_id" => "ch2", "last_read_event_id" => "ev-2"}
                 ],
                 "rows_read" => 2,
                 "truncated" => false
               }
             },
             %{
               "name" => "user-b",
               "ok" => true,
               "result" => %{
                 "columns" => ["channel_id", "last_read_event_id"],
                 "rows" => [],
                 "rows_read" => 0,
                 "truncated" => false
               }
             }
           ]
         })}
      end)

    assert {:ok, %{rows: rows, truncated_instances: 0}} =
             DebugExport.export_read_state(base, "tok", ["user-a", "user-b"])

    assert [
             %{user_id: "user-a", channel_id: "ch1", last_read_event_id: "ev-1"},
             %{user_id: "user-a", channel_id: "ch2", last_read_event_id: "ev-2"}
           ] = rows
  end

  test "export_read_state fails when an instance errors" do
    base =
      start_stub!(fn _path, _body ->
        {200,
         Jason.encode!(%{
           "results" => [%{"name" => "user-a", "ok" => false, "error" => "boom"}]
         })}
      end)

    assert {:error, reason} = DebugExport.export_read_state(base, "tok", ["user-a"])
    assert reason =~ "user-a"
    assert reason =~ "boom"
  end

  test "export_read_state surfaces non-2xx responses" do
    base =
      start_stub!(fn _path, _body ->
        {403, ~s|{"error":{"code":"FORBIDDEN"}}|}
      end)

    assert {:error, %{status: 403}} = DebugExport.export_read_state(base, "tok", ["user-a"])
  end

  test "export_invite_index tags rows with the channel_id (DO instance name)" do
    base =
      start_stub!(fn _path, _body ->
        {200,
         Jason.encode!(%{
           "class" => "ChatChannel",
           "instance_count" => 1,
           "results" => [
             %{
               "name" => "ch-x",
               "ok" => true,
               "result" => %{
                 "columns" => ["invite_code", "created_by"],
                 "rows" => [%{"invite_code" => "inv-1", "created_by" => "user-a"}],
                 "rows_read" => 1,
                 "truncated" => false
               }
             }
           ]
         })}
      end)

    assert {:ok, %{rows: [row]}} = DebugExport.export_invite_index(base, "tok")
    assert row["invite_code"] == "inv-1"
    assert row["channel_id"] == "ch-x"
  end
end
