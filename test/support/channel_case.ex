defmodule LiliumChatWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix Channel tests (issue #8).

  Provides `Phoenix.ChannelTest` conveniences and the Ecto sandbox
  for DB-backed channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint LiliumChatWeb.Endpoint
      import Phoenix.ChannelTest
      import LiliumChatWeb.ChannelCase
    end
  end

  setup tags do
    LiliumChat.DataCase.setup_sandbox(tags)
    :ok
  end
end
