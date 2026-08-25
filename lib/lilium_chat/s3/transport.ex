defmodule LiliumChat.S3.Transport.Httpc do
  @moduledoc """
  Default S3/SeaweedFS HEAD transport using the built-in `:httpc` (inets).

  Only `head/1` is needed for `finalize` (a public-read HEAD, no SigV4). It is
  exercised in dev / manual real-S3 E2E; unit tests inject a fake transport via
  `LiliumChat.S3.Config.transport` (see `LiliumChat.S3.TestTransport`), and
  `test/lilium_chat/s3_transport_test.exs` exercises THIS transport against a
  local `:httpd` server.

  OTP 29 `:httpc` notes (issue #27, verified in-container):

  * `:httpc.request/4` is `request(Method, Request, HTTPOptions, Options)` —
    Method is an atom (`:head`) and Request is `{url_charlist, headers}`.
    (The pre-#27 code passed `[]` as the Method, so every HEAD returned
    `{:error, :invalid_method}` and finalize was 415 against a real store
    even when the object existed.)
  * In this OTP build the inets app starts with its ebin directory missing
    from the code path, so lazily loaded modules (e.g. `:http_util`) fail
    with `:nofile` at request time — `ensure_httpc_ready/0` pins the ebin back
    on the path (same workaround as `LiliumChat.DebugExport`).
  """

  # :httpc has no @spec in this OTP build's header file Elixir resolves —
  # silence the undefined-function warning (same as debug_export.ex).
  @compile {:no_warn_undefined, :httpc}

  @spec head(String.t()) :: {:ok, integer(), [tuple()]} | {:error, term()}
  def head(url) do
    ensure_httpc_ready()

    case :httpc.request(:head, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_version, status, _reason}, headers, _body}} ->
        {:ok, status, headers}

      {:ok, {status, _body}} when is_integer(status) ->
        {:ok, status, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Idempotent pre-flight: start inets + ssl and pin `lib/inets-*/ebin` back on
  the code path if this OTP build dropped it (see module doc). Public so
  tests can start other inets components (`:httpd`) before first use.
  """
  @spec ensure_httpc_ready() :: :ok
  def ensure_httpc_ready do
    :application.ensure_all_started(:inets)
    :application.ensure_all_started(:ssl)

    if :code.ensure_loaded(:http_util) == {:module, :http_util} do
      :ok
    else
      root = to_string(:code.root_dir())

      for dir <- Path.wildcard(Path.join(root, "lib/inets-*/ebin")) do
        # code:add_patha/1 requires a charlist (Erlang string()).
        :code.add_patha(String.to_charlist(dir))
      end

      case :code.ensure_loaded(:http_util) do
        {:module, _} -> :ok
        {:error, reason} -> raise "failed to load http_util: #{inspect(reason)}"
      end
    end
  end
end
