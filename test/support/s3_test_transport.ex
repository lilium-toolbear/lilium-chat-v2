defmodule LiliumChat.S3.TestTransport do
  @moduledoc """
  Fake S3 HEAD transport for tests (issue #14).

  Its behaviour is controlled per-test via
  `Application.put_env(:lilium_chat, :s3_fake_head, value)`:

      # full match
      {:ok, 200, %{"content-type" => "image/png", "content-length" => "12345"}}
      # 404
      {:ok, 404, %{}}
      # transport error
      {:error, :econnrefused}

  When unset, `head/1` returns a transport error so a misconfigured test fails
  loudly instead of passing. (Each test sets its own value in `setup`/per-test;
  the S3 test files run with `async: false`, so the shared key is never raced.)
  """

  @doc false
  def head(_url) do
    Application.get_env(:lilium_chat, :s3_fake_head, {:error, :s3_fake_head_not_configured})
  end
end
