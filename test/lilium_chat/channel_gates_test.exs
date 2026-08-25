defmodule LiliumChat.ChannelGatesTest do
  @moduledoc """
  `ChannelGates.dissolved/1` unit tests (issue #26 B3).

  The helper re-reads `channels.status` fresh (caller runs it inside its
  transaction); these tests pin the gate logic itself. The mid-txn race
  (dissolve committing between a pre-txn `meta` snapshot and the in-txn read)
  is not testable here — the Ecto sandbox ownership pool serializes every
  query onto one connection — and is covered by integration tests in
  `MessageSendTest` (dissolved → CHANNEL_DISSOLVED; committed duplicate →
  cached replay).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{ChannelGates, Errors, Repo}

  test "dissolved/1 returns CHANNEL_DISSOLVED only for dissolved channels" do
    cid = "ch-gates-" <> Ecto.UUID.generate()
    seed_channel(cid, status: "active")

    assert ChannelGates.dissolved(cid) == :ok

    Repo.query!("UPDATE chat_v2.channels SET status = 'dissolved' WHERE channel_id = $1", [cid])

    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED"}} =
             ChannelGates.dissolved(cid)
  end

  test "dissolved/1 for a missing channel → :ok (channels are never deleted)" do
    # The caller's pre-txn `load_meta` already failed CHANNEL_NOT_FOUND before
    # reaching the txn gate; a vanished row can only mean the DB lost it.
    assert ChannelGates.dissolved("ch-gates-missing") == :ok
  end
end
