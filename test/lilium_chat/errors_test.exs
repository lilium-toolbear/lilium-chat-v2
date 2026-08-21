defmodule LiliumChat.ErrorsTest do
  use ExUnit.Case, async: true

  alias LiliumChat.Errors

  @expected_status_by_code %{
    "UNAUTHORIZED" => 401,
    "MACHINE_TOKEN_NOT_ALLOWED" => 401,
    "SESSION_NOT_ALLOWED" => 403,
    "FORBIDDEN" => 403,
    "CHANNEL_NOT_FOUND" => 404,
    "MESSAGE_NOT_FOUND" => 404,
    "MEMBER_NOT_FOUND" => 404,
    "INVITE_NOT_FOUND" => 404,
    "INVITE_NOT_AVAILABLE" => 409,
    "CHANNEL_ARCHIVED" => 409,
    "CHANNEL_DISSOLVED" => 409,
    "MESSAGE_NOT_EDITABLE" => 409,
    "IDEMPOTENCY_CONFLICT" => 409,
    "ROUTE_INDEX_PENDING" => 409,
    "ATTACHMENT_TOO_LARGE" => 413,
    "ARCHIVE_RECORD_TOO_LARGE" => 413,
    "UNSUPPORTED_ATTACHMENT_TYPE" => 415,
    "INVALID_MESSAGE" => 422,
    "INVALID_MEMBER_ROLE" => 422,
    "INVALID_STICKER_SOURCE" => 422,
    "COMMAND_NAME_CONFLICT" => 409,
    "COMMAND_NOT_FOUND" => 404,
    "COMMAND_NOT_ALLOWED" => 403,
    "COMMAND_PERMISSION_DENIED" => 403,
    "COMMAND_OPTIONS_INVALID" => 422,
    "COMMAND_MANIFEST_VERSION_STALE" => 409,
    "STATEFUL_SESSION_BUSY" => 409,
    "STATEFUL_SESSION_NOT_FOUND" => 404,
    "STATEFUL_SESSION_NOT_ACTIVE" => 409,
    "STATEFUL_SESSION_PERMISSION_DENIED" => 403,
    "STATEFUL_SESSION_EXPIRED" => 410,
    "STATEFUL_INPUT_BACKLOG_OVERFLOW" => 429,
    "SESSION_STOP_IN_PROGRESS" => 409,
    "PIN_NOT_FOUND" => 404,
    "PIN_FORBIDDEN" => 403,
    "PIN_SOURCE_INVALID" => 422,
    "INVALID_COMMAND_OPTIONS" => 422,
    "COMPONENT_NOT_FOUND" => 404,
    "COMPONENT_DISABLED" => 409,
    "COMPONENT_ALREADY_USED" => 409,
    "INTERACTION_ALREADY_SUBMITTED" => 409,
    "INTERACTION_FORBIDDEN_TARGET" => 403,
    "INVALID_INTERACTION_VALUE" => 422,
    "RATE_LIMITED" => 429,
    "BOT_CALLBACK_UNAVAILABLE" => 503,
    "BOT_OFFLINE" => 503,
    "BOT_NOT_FOUND" => 404,
    "BOT_TOKEN_INVALID" => 401,
    "BOT_TOKEN_REVOKED" => 401,
    "BOT_SCOPE_DENIED" => 403,
    "BOT_DISABLED" => 403,
    "BOT_COMMAND_DISABLED" => 409,
    "BOT_EFFECT_INVALID" => 422,
    "BOT_EFFECT_CONFLICT" => 409,
    "BOT_STREAM_NOT_FOUND" => 404,
    "BOT_STREAM_CONFLICT" => 409,
    "BOT_STREAM_SEQUENCE_GAP" => 409,
    "BOT_STREAM_EXPIRED" => 410,
    "CHAT_WORKER_UNAVAILABLE" => 503,
    "EVENT_GAP" => 409,
    "SESSION_NOT_LIVE" => 409,
    "STICKER_NOT_FOUND" => 404,
    "STICKER_LIBRARY_LIMIT_EXCEEDED" => 409,
    "INVALID_DM_TARGET" => 422,
    "DM_TARGET_NOT_FOUND" => 404,
    "UNSUPPORTED_CHANNEL_KIND" => 409,
    "ADMIN_ACCESS_REQUIRED" => 403,
    "OFFICIAL_COMMAND_AUTO_ALLOWED" => 409
  }

  @expected_retryable MapSet.new([
                        "CHAT_WORKER_UNAVAILABLE",
                        "ROUTE_INDEX_PENDING",
                        "RATE_LIMITED",
                        "BOT_CALLBACK_UNAVAILABLE",
                        "BOT_OFFLINE",
                        "BOT_STREAM_SEQUENCE_GAP"
                      ])

  test "exposes exactly the 68 contract error codes with verbatim statuses" do
    assert Errors.http_status_by_code() == @expected_status_by_code
    assert map_size(Errors.http_status_by_code()) == 68
  end

  test "retryable set is exactly the 6 contract codes" do
    assert Errors.retryable_codes() == @expected_retryable
  end

  test "RATE_LIMITED keeps its 429 mapping and retryable flag (D9: kept, never thrown)" do
    assert Errors.status_for("RATE_LIMITED") == 429
    assert Errors.retryable?("RATE_LIMITED")
  end

  test "unknown codes fall back to 500 / not-retryable, as in the old Worker" do
    assert Errors.status_for("NOT_A_REAL_CODE") == 500
    refute Errors.retryable?("NOT_A_REAL_CODE")
  end

  test "new/2 builds a fully-populated ApiError with plug_status" do
    err = Errors.new("MACHINE_TOKEN_NOT_ALLOWED")

    assert %LiliumChat.Errors.ApiError{
             code: "MACHINE_TOKEN_NOT_ALLOWED",
             message: "Machine tokens are not allowed",
             retryable: false,
             http_status: 401,
             plug_status: :unauthorized
           } = err

    assert Plug.Exception.status(err) == 401
    assert Exception.message(err) == "Machine tokens are not allowed"
  end

  test "new/2 accepts a message override (per throw site, as in the old Worker)" do
    err = Errors.new("UNAUTHORIZED", "Not authenticated")
    assert err.message == "Not authenticated"
    assert err.http_status == 401
  end

  test "envelope matches contract §2.6 exactly" do
    err = Errors.new("FORBIDDEN", "not a channel member")

    assert Errors.envelope(err, "req_abc123") == %{
             error: %{code: "FORBIDDEN", message: "not a channel member", retryable: false},
             request_id: "req_abc123"
           }
  end

  test "envelope carries retryable true for retryable codes" do
    err = Errors.new("CHAT_WORKER_UNAVAILABLE")
    assert Errors.envelope(err, "req_x").error.retryable == true
    assert err.http_status == 503
  end
end
