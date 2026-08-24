defmodule LiliumChat.InviteFixtures do
  @moduledoc """
  Invite fixtures shared by the invite test files (issue #13).
  """

  @doc """
  The personal stable invite code (old Worker `personalInviteCode`): the
  first 8 bytes, hex lowercase, of `SHA-256("lilium-invite:v1:<channel>:<user>")`.
  """
  def personal_code(channel_id, user_id) do
    :crypto.hash(:sha256, "lilium-invite:v1:#{channel_id}:#{user_id}")
    |> :binary.part(0, 8)
    |> Base.encode16(case: :lower)
  end
end
