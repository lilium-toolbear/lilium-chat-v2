defmodule LiliumChatWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias LiliumChat.Errors

  setup do
    Process.put(:lilium_chat_request_id, "req_test-123")
    :ok
  end

  test "renders an ApiError reason as its own contract envelope" do
    api_error = Errors.new("FORBIDDEN", "not a channel member")

    json =
      LiliumChatWeb.ErrorJSON.render("403.json", %{
        kind: :error,
        reason: api_error,
        status: 403
      })

    assert json == %{
             error: %{code: "FORBIDDEN", message: "not a channel member", retryable: false},
             request_id: "req_test-123"
           }
  end

  test "renders unknown reasons as CHAT_WORKER_UNAVAILABLE (appOnError parity)" do
    json =
      LiliumChatWeb.ErrorJSON.render("500.json", %{
        kind: :error,
        reason: %RuntimeError{message: "boom"},
        status: 500
      })

    assert json == %{
             error: %{
               code: "CHAT_WORKER_UNAVAILABLE",
               message: "worker temporarily unavailable",
               retryable: true
             },
             request_id: "req_test-123"
           }
  end

  test "falls back to a fresh req_<uuidv7> when no request id is in flight" do
    Process.delete(:lilium_chat_request_id)

    json = LiliumChatWeb.ErrorJSON.render("500.json", %{})

    assert json.request_id =~
             ~r/^req_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end
end
