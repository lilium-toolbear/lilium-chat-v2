defmodule LiliumChat.ChannelGates do
  @moduledoc """
  Shared write-path channel gates (issue #26 B3).

  `dissolved/1` re-reads `chat_v2.channels.status` INSIDE the caller's
  transaction (old Worker `channelMetaStatusVisibility` runs inside
  `ctx.storage.transaction`), so a dissolve committed after a pre-txn `meta`
  snapshot is still caught under READ COMMITTED. Used by `MessageSend` and
  `MessageMutate` — the pre-txn `meta` read (existence + `membership_version`)
  stays at the call site; only the dissolved gate needs the fresh read.
  """

  alias LiliumChat.{Errors, Query, Repo}

  @doc """
  `{:error, CHANNEL_DISSOLVED}` when the channel is currently dissolved,
  else `:ok`. Must run inside the caller's transaction to be race-free.
  """
  def dissolved(channel_id) do
    case Query.rows(
           Repo.query(
             "SELECT status FROM chat_v2.channels WHERE channel_id = $1",
             [channel_id]
           )
         ) do
      [%{"status" => "dissolved"}] ->
        {:error, Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")}

      _ ->
        :ok
    end
  end
end
