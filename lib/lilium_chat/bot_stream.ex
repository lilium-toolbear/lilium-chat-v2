defmodule LiliumChat.BotStream do
  @moduledoc """
  Bot Stream WS frame codec (contract §9.15.2, issue #18).

  Pure builders/parsers for `lilium.chat.bot.stream.v1`, mirroring the old
  Worker's `src/chat/bot-stream-protocol.ts`.
  """

  alias LiliumChat.Errors

  @api_version "lilium.chat.bot.stream.v1"

  @doc "The Bot Stream API version (WS subprotocol)."
  def api_version, do: @api_version

  @doc "Scopes required to open a Stream WS (old Worker `verifyBotStreamConnectScopes`)."
  def connect_scopes, do: ["chat:runtime:connect", "chat:messages:write"]

  # ---------------------------------------------------------------- hello

  def parse_hello(%{} = frame) do
    with :ok <- check_type(frame, "hello"),
         :ok <- check_api_version(frame) do
      {:ok, %{}}
    end
  end

  def parse_hello(_), do: {:error, "not a hello frame"}

  def build_ready(%{channel_id: cid, message_id: mid, expires_at: exp, ack_seq: ack}) do
    %{
      "type" => "ready",
      "api_version" => @api_version,
      "channel_id" => cid,
      "message_id" => mid,
      "expires_at" => exp,
      "ack_seq" => ack
    }
  end

  # ---------------------------------------------------------------- append

  def parse_append(%{} = frame) do
    with :ok <- check_type(frame, "append"),
         :ok <- check_api_version(frame),
         {:ok, seq} <- require_integer(frame, "seq"),
         {:ok, delta} <- require_string(frame, "delta") do
      {:ok, %{seq: seq, delta: delta}}
    end
  end

  def parse_append(_), do: {:error, "not an append frame"}

  def build_append_ack(ack_seq) when is_integer(ack_seq) do
    %{"type" => "append_ack", "api_version" => @api_version, "ack_seq" => ack_seq}
  end

  # -------------------------------------------------------------- finalize

  def parse_finalize(%{} = frame) do
    with :ok <- check_type(frame, "finalize"),
         :ok <- check_api_version(frame),
         {:ok, final_seq} <- require_integer(frame, "final_seq") do
      {:ok,
       %{
         final_seq: final_seq,
         components: optional_list(frame, "components"),
         attachment_ids: optional_list(frame, "attachment_ids")
       }}
    end
  end

  def parse_finalize(_), do: {:error, "not a finalize frame"}

  def build_finalized_ack(message_id, event_id) do
    %{
      "type" => "finalized_ack",
      "api_version" => @api_version,
      "ok" => true,
      "message_id" => message_id,
      "event_id" => event_id
    }
  end

  # ----------------------------------------------------------------- error

  def build_error(%Errors.ApiError{} = error) do
    build_error(error.code, error.message)
  end

  def build_error(code, message) when is_binary(code) and is_binary(message) do
    %{
      "type" => "stream_error",
      "api_version" => @api_version,
      "code" => code,
      "message" => message,
      "retryable" => Errors.retryable?(code)
    }
  end

  # -------------------------------------------------------------- ping/pong

  def parse_ping(%{} = frame) do
    with :ok <- check_type(frame, "ping"),
         :ok <- check_api_version(frame) do
      {:ok, %{}}
    end
  end

  def parse_ping(_), do: {:error, "not a ping frame"}

  def build_pong do
    %{"type" => "pong", "api_version" => @api_version}
  end

  # -------------------------------------------------------------- hashing

  @doc """
  SHA-256 hex of a stream delta (old Worker `hashStreamDelta`).
  """
  def hash_delta(delta) when is_binary(delta) do
    :crypto.hash(:sha256, delta) |> Base.encode16(case: :lower)
  end

  @doc """
  Finalize request hash (contract §9.15.4): SHA-256 over canonical JSON
  `{final_seq, resolved_text, components, attachment_ids}` with components
  forced to `[]`.
  """
  def finalize_request_hash(final_seq, resolved_text, attachment_ids \\ []) do
    LiliumChat.CanonicalJSON.encode_and_sha256([
      {"final_seq", final_seq},
      {"resolved_text", resolved_text},
      {"components", []},
      {"attachment_ids", attachment_ids || []}
    ])
  end

  def text_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  # ------------------------------------------------------------- internals

  defp check_type(%{"type" => type}, type), do: :ok
  defp check_type(_, expected), do: {:error, "not a #{expected} frame"}

  defp check_api_version(%{"api_version" => @api_version}), do: :ok
  defp check_api_version(_), do: {:error, "invalid api_version"}

  defp require_integer(frame, key) do
    case frame[key] do
      n when is_integer(n) -> {:ok, n}
      _ -> {:error, "#{key} must be an integer"}
    end
  end

  defp require_string(frame, key) do
    case frame[key] do
      s when is_binary(s) -> {:ok, s}
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp optional_list(frame, key) do
    case frame[key] do
      list when is_list(list) -> list
      _ -> nil
    end
  end
end
