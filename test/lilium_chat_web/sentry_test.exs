defmodule LiliumChatWeb.SentryTest do
  @moduledoc """
  Sentry capture tests (spec §10 / A13, issue #21): unhandled exceptions
  are reported with the request id so events are searchable by it. Uses
  `Sentry.Test` (local Bypass server) so nothing leaves the test VM.
  """

  use LiliumChatWeb.ConnCase, async: true

  import Plug.Conn
  import LiliumChat.TestJWT

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  setup do
    Sentry.Test.setup_sentry(dedup_events: false)
    :ok
  end

  test "an unknown exception is reported to Sentry with the request id" do
    conn = boom_request()

    # Old-Worker onError parity: unknown exceptions render 503.
    assert conn.status == 503
    assert %{"error" => %{"code" => "CHAT_WORKER_UNAVAILABLE"}} = Jason.decode!(conn.resp_body)

    assert [event] = Sentry.Test.pop_sentry_reports()
    assert event.original_exception == %RuntimeError{message: "test boom"}
    # The extra map is kept as passed (atom keys in the collected struct;
    # JSON-encoded string keys only at the wire).
    assert event.extra[:request_id] =~ ~r/^req_/
  end

  test "ApiErrors (contract business results) are never reported" do
    conn =
      Plug.Test.conn(:get, "/api/chat/channels")
      |> then(&LiliumChatWeb.Endpoint.call(&1, LiliumChatWeb.Endpoint.init([])))

    assert conn.status == 401
    assert Sentry.Test.pop_sentry_reports() == []
  end

  defp boom_request do
    Plug.Test.conn(:get, "/api/chat/__test/boom")
    |> put_req_header("authorization", "Bearer " <> sign(%{"sub" => @uid}))
    |> then(&LiliumChatWeb.Endpoint.call(&1, LiliumChatWeb.Endpoint.init([])))
  end
end
