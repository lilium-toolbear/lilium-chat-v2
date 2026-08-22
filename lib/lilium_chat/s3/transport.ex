defmodule LiliumChat.S3.Transport.Httpc do
  @moduledoc """
  Default S3/SeaweedFS HEAD transport using the built-in `:httpc` (inets).

  Only `head/1` is needed for `finalize` (a public-read HEAD, no SigV4). It is
  exercised in dev / manual real-S3 E2E; unit tests inject a fake transport via
  `LiliumChat.S3.Config.transport` (see `LiliumChat.S3.TestTransport`).
  """

  @spec head(String.t()) :: {:ok, integer(), [{atom(), binary()}]} | {:error, term()}
  def head(url) do
    :application.ensure_all_started(:inets)

    case :httpc.request([], {:binary, url, :HEAD}, [], []) do
      {:ok, {{_version, status, _reason}, headers}} ->
        {:ok, status, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
