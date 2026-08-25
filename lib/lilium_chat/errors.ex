defmodule LiliumChat.Errors do
  @moduledoc """
  API error contract (contract §11 / spec §6.3, issue #2).

  Single source of truth for the 68 error codes, their HTTP status mapping,
  and the 6 retryable codes — copied verbatim from the old Worker's
  `src/errors.ts` (`HTTP_STATUS_BY_CODE` + `RETRYABLE_CODES`). The contract
  table in `docs/api-contract.md` §11 is the normative reference; when in
  doubt, the code table here must match it.

  Error envelope (contract §2.6):

      {
        "error": { "code": "...", "message": "...", "retryable": false },
        "request_id": "req_..."
      }

  D9: `RATE_LIMITED` (429) is kept for contract compatibility but is never
  thrown by this implementation (rate limiting is not implemented).
  """

  alias LiliumChat.Errors.ApiError

  defmodule ApiError do
    @moduledoc """
    Typed API error carrying a contract code. `plug_status` lets the
    Phoenix endpoint fallback path pick the right HTTP status; `http_status`
    is the same value as an integer for direct rendering.
    """

    defexception [:code, :message, :retryable, :http_status, :plug_status]

    @impl true
    def message(%__MODULE__{message: message}), do: message
  end

  @doc """
  All 68 error codes with their HTTP status, copied verbatim from the old
  Worker `src/errors.ts` `HTTP_STATUS_BY_CODE`.
  """
  def http_status_by_code do
    %{
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
  end

  @doc """
  The 6 retryable codes, copied verbatim from the old Worker `src/errors.ts`
  `RETRYABLE_CODES`.
  """
  def retryable_codes do
    MapSet.new([
      "CHAT_WORKER_UNAVAILABLE",
      "ROUTE_INDEX_PENDING",
      "RATE_LIMITED",
      "BOT_CALLBACK_UNAVAILABLE",
      "BOT_OFFLINE",
      "BOT_STREAM_SEQUENCE_GAP"
    ])
  end

  @doc """
  Canonical short English messages (contract §2.6: `message` is a human-facing
  English phrase). Callers may override per throw site, as the old Worker did.
  """
  def default_messages do
    %{
      "UNAUTHORIZED" => "Invalid or expired token",
      "MACHINE_TOKEN_NOT_ALLOWED" => "Machine tokens are not allowed",
      "SESSION_NOT_ALLOWED" => "Chat requires a direct user session",
      "FORBIDDEN" => "Forbidden",
      "CHANNEL_NOT_FOUND" => "Channel not found",
      "MESSAGE_NOT_FOUND" => "Message not found",
      "MEMBER_NOT_FOUND" => "Member not found",
      "INVITE_NOT_FOUND" => "Invite not found",
      "INVITE_NOT_AVAILABLE" => "Invite not available",
      "CHANNEL_ARCHIVED" => "Channel is archived",
      "CHANNEL_DISSOLVED" => "Channel is dissolved",
      "MESSAGE_NOT_EDITABLE" => "Message is not editable",
      "IDEMPOTENCY_CONFLICT" => "idempotency key reused with different request body",
      "ROUTE_INDEX_PENDING" => "Route index pending",
      "ATTACHMENT_TOO_LARGE" => "Attachment too large",
      "ARCHIVE_RECORD_TOO_LARGE" => "Archive record too large",
      "UNSUPPORTED_ATTACHMENT_TYPE" => "Unsupported attachment type",
      "INVALID_MESSAGE" => "Invalid message",
      "INVALID_MEMBER_ROLE" => "Invalid member role",
      "INVALID_STICKER_SOURCE" => "Invalid sticker source",
      "COMMAND_NAME_CONFLICT" => "Command name conflict",
      "COMMAND_NOT_FOUND" => "Command not found",
      "COMMAND_NOT_ALLOWED" => "Command not allowed",
      "COMMAND_PERMISSION_DENIED" => "Command permission denied",
      "COMMAND_OPTIONS_INVALID" => "Command options invalid",
      "COMMAND_MANIFEST_VERSION_STALE" => "Command manifest version stale",
      "STATEFUL_SESSION_BUSY" => "Stateful session busy",
      "STATEFUL_SESSION_NOT_FOUND" => "Stateful session not found",
      "STATEFUL_SESSION_NOT_ACTIVE" => "Stateful session not active",
      "STATEFUL_SESSION_PERMISSION_DENIED" => "Stateful session permission denied",
      "STATEFUL_SESSION_EXPIRED" => "Stateful session expired",
      "STATEFUL_INPUT_BACKLOG_OVERFLOW" => "Stateful input backlog overflow",
      "SESSION_STOP_IN_PROGRESS" => "Session stop in progress",
      "PIN_NOT_FOUND" => "Pin not found",
      "PIN_FORBIDDEN" => "Pin forbidden",
      "PIN_SOURCE_INVALID" => "Invalid pin source",
      "INVALID_COMMAND_OPTIONS" => "Invalid command options",
      "COMPONENT_NOT_FOUND" => "Component not found",
      "COMPONENT_DISABLED" => "Component disabled",
      "COMPONENT_ALREADY_USED" => "Component already used",
      "INTERACTION_ALREADY_SUBMITTED" => "Interaction already submitted",
      "INTERACTION_FORBIDDEN_TARGET" => "Interaction forbidden target",
      "INVALID_INTERACTION_VALUE" => "Invalid interaction value",
      "RATE_LIMITED" => "Rate limited",
      "BOT_CALLBACK_UNAVAILABLE" => "Bot callback unavailable",
      "BOT_OFFLINE" => "Bot offline",
      "BOT_NOT_FOUND" => "Bot not found",
      "BOT_TOKEN_INVALID" => "Bot token invalid",
      "BOT_TOKEN_REVOKED" => "Bot token revoked",
      "BOT_SCOPE_DENIED" => "Bot scope denied",
      "BOT_DISABLED" => "Bot disabled",
      "BOT_COMMAND_DISABLED" => "Bot command disabled",
      "BOT_EFFECT_INVALID" => "Bot effect invalid",
      "BOT_EFFECT_CONFLICT" => "Bot effect conflict",
      "BOT_STREAM_NOT_FOUND" => "Bot stream not found",
      "BOT_STREAM_CONFLICT" => "Bot stream conflict",
      "BOT_STREAM_SEQUENCE_GAP" => "Bot stream sequence gap",
      "BOT_STREAM_EXPIRED" => "Bot stream expired",
      "CHAT_WORKER_UNAVAILABLE" => "worker temporarily unavailable",
      "EVENT_GAP" => "Event gap",
      "SESSION_NOT_LIVE" => "Session not live",
      "STICKER_NOT_FOUND" => "Sticker not found",
      "STICKER_LIBRARY_LIMIT_EXCEEDED" => "Sticker library limit exceeded",
      "INVALID_DM_TARGET" => "Invalid DM target",
      "DM_TARGET_NOT_FOUND" => "DM target not found",
      "UNSUPPORTED_CHANNEL_KIND" => "Unsupported channel kind",
      "ADMIN_ACCESS_REQUIRED" => "Admin access required",
      "OFFICIAL_COMMAND_AUTO_ALLOWED" => "Official command auto allowed"
    }
  end

  @doc "HTTP status for a code (unknown codes fall back to 500, as in the old Worker)."
  def status_for(code) do
    Map.get(http_status_by_code(), code, 500)
  end

  @doc "Whether a code is retryable (contract §11: exactly 6 codes are)."
  def retryable?(code), do: code in retryable_codes()

  @doc "Canonical message for a code."
  def default_message(code) do
    Map.get(default_messages(), code, String.replace(code, ~r/_/, " "))
  end

  @doc """
  Build an `ApiError` for `code`, optionally overriding the message.
  `retryable` and `http_status` always derive from the contract tables.
  """
  def new(code, message \\ nil) when is_binary(code) do
    status = status_for(code)

    # Issue #21 / spec §10: idempotency 冲突率. `Errors.new/2` is the single
    # funnel every IDEMPOTENCY_CONFLICT flows through (user_command via
    # LiliumChat.Idempotency.check, uploads, bot_effect and session_effect
    # namespaces all raise/construct here), so the counter increments once
    # per conflict construction without touching 4+ call sites. The count
    # tracks conflicts (each conflict is raised once at the funnel; re-
    # wrapping an already-constructed error does not re-count).
    # telemetry_metrics_prometheus_core turns the event into a counter; with
    # no handler attached the execute is a no-op.
    if code == "IDEMPOTENCY_CONFLICT" do
      :telemetry.execute([:lilium_chat, :idempotency, :conflict], %{count: 1}, %{})
    end

    %ApiError{
      code: code,
      message: message || default_message(code),
      retryable: retryable?(code),
      http_status: status,
      plug_status: Plug.Conn.Status.reason_atom(status)
    }
  end

  @doc """
  The contract error envelope (contract §2.6):
  `%{error: %{code, message, retryable}, request_id}`.
  """
  def envelope(%ApiError{} = api_error, request_id) do
    %{
      error: %{
        code: api_error.code,
        message: api_error.message,
        retryable: api_error.retryable
      },
      request_id: request_id
    }
  end
end
