defmodule LiliumChat.DmsTest do
  @moduledoc """
  DM get-or-create tests (issue #13, contract §5.2c): `dm.open` via
  `LiliumChat.Dms.open/3` (routing + writer op on the target channel's
  writer, D13).

  Covers: fresh-create effects (dm_pairs, channel shell, both members,
  `this.created` bookkeeping event, audit row), pair resolution (B opens
  the SAME channel A created), idempotent replay + conflict (different
  recipient under the same key), validation (missing / self / non-UUID /
  unknown recipient), the full ChannelSummary response (peer title /
  avatar / dm_peer, raw-text preview, unread_count 0), and the wire-set
  filter that keeps `this.created` out of the replay pages.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Dms, Query, Repo, Timeline}

  @a "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @b "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"
  @c "8b3e4e5f-6c7d-9e0f-1a2b-3c4d5e6f7081"

  # ----------------------------------------------------------------- helpers

  defp dm_pair(user_a, user_b) do
    {low, high} = if user_a <= user_b, do: {user_a, user_b}, else: {user_b, user_a}
    "#{low}:#{high}"
  end

  defp pair_row(pair_key) do
    Query.rows(
      Repo.query("SELECT * FROM chat_v2.dm_pairs WHERE pair_key = $1", [pair_key], type: true)
    )
    |> List.first()
  end

  defp channel_row(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT channel_id, kind, visibility, title, status, member_count, membership_version " <>
          "FROM chat_v2.channels WHERE channel_id = $1",
        [channel_id],
        type: true
      )
    )
    |> List.first()
  end

  defp member_row(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT user_id, role, status, joined_at FROM chat_v2.channel_members " <>
          "WHERE channel_id = $1 AND user_id = $2",
        [channel_id, user_id],
        type: true
      )
    )
    |> List.first()
  end

  defp events(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT event_id, event_type, payload FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id",
        [channel_id],
        type: true
      )
    )
  end

  defp audit_rows(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT audit_id, actor_kind, actor_id, action, target_type, target_id " <>
          "FROM chat_v2.audit_logs WHERE target_id = $1 ORDER BY created_at",
        [channel_id]
      )
    )
  end

  # ----------------------------------------------------------------- fresh

  test "fresh open → dm_pairs + channel + both members + this.created + audit" do
    seed_profile(@a, "Alice", "https://avatars.example.com/a.png")
    seed_profile(@b, "Bob", "https://avatars.example.com/b.png")

    {:ok, response} = Dms.open(@a, "key-dm1", %{"recipient_user_id" => @b})

    pair_key = dm_pair(@a, @b)
    pair = pair_row(pair_key)
    assert pair != nil
    assert pair["user_low"] == min(@a, @b)
    assert pair["user_high"] == max(@a, @b)
    assert pair["created_by"] == @a
    assert pair["status"] == "active"

    cid = pair["channel_id"]
    meta = channel_row(cid)
    assert meta["kind"] == "dm"
    assert meta["visibility"] == "private"
    assert meta["title"] == ""
    assert meta["status"] == "active"
    assert meta["member_count"] == 2
    assert meta["membership_version"] == 1

    assert member_row(cid, @a) != nil
    assert member_row(cid, @b) != nil

    [created] = events(cid)
    assert created["event_type"] == "this.created"
    payload = created["payload"]
    assert payload["channel"]["channel_id"] == cid
    assert payload["channel"]["kind"] == "dm"
    assert payload["channel"]["visibility"] == "private"
    assert payload["actor_kind"] == "user"
    assert payload["actor_id"] == @a

    [audit] = audit_rows(cid)
    assert audit["action"] == "this.create_dm"
    assert audit["actor_kind"] == "user"
    assert audit["actor_id"] == @a
    assert audit["target_type"] == "channel"
    assert audit["target_id"] == cid

    # The response last_event_id is the this.created event id.
    assert response["channel"]["last_event_id"] == created["event_id"]
  end

  test "fresh open response: full DM ChannelSummary + membership" do
    seed_profile(@a, "Alice", "https://avatars.example.com/a.png")
    seed_profile(@b, "Bob", "https://avatars.example.com/b.png")

    {:ok, response} = Dms.open(@a, "key-dm2", %{"recipient_user_id" => @b})

    ch = response["channel"]
    assert ch["kind"] == "dm"
    assert ch["visibility"] == "private"
    # Title / avatar resolve to the PEER (old Worker inflate parity).
    assert ch["title"] == "Bob"
    assert ch["avatar_url"] == "https://avatars.example.com/b.png"
    assert ch["topic"] == nil
    assert ch["status"] == "active"
    assert ch["member_count"] == 2
    assert ch["role"] == "member"
    assert ch["unread_count"] == 0
    assert ch["last_read_event_id"] == nil
    assert ch["last_message_preview"] == nil
    assert ch["last_message_at"] == nil
    assert is_binary(ch["last_event_id"])
    assert is_binary(ch["created_at"])
    assert is_binary(ch["updated_at"])

    assert ch["dm_peer"] == %{
             "user_id" => @b,
             "display_name" => "Bob",
             "avatar_url" => "https://avatars.example.com/b.png"
           }

    assert response["membership"]["role"] == "member"
    assert is_binary(response["membership"]["joined_at"])
  end

  test "peer without a display name → fallback name, null avatar" do
    seed_profile(@a, "Alice", nil)
    # The recipient row EXISTS (so openDm finds it) but has no full_name —
    # the summary falls back to `user-<first 8 hex>`.
    seed_profile(@b, nil, nil)

    {:ok, response} = Dms.open(@a, "key-dm-fallback", %{"recipient_user_id" => @b})

    ch = response["channel"]
    fallback = "user-" <> String.slice(String.downcase(@b), 0, 8)
    assert ch["title"] == fallback
    assert ch["avatar_url"] == nil
    assert ch["dm_peer"]["display_name"] == fallback
  end

  # ---------------------------------------------------------- pair resolution

  test "B opening the same pair reuses A's channel (get-or-create)" do
    seed_profile(@a, "Alice", nil)
    seed_profile(@b, "Bob", nil)

    {:ok, first} = Dms.open(@a, "key-dm3", %{"recipient_user_id" => @b})
    {:ok, second} = Dms.open(@b, "key-dm4", %{"recipient_user_id" => @a})

    assert second["channel"]["channel_id"] == first["channel"]["channel_id"]
    cid = first["channel"]["channel_id"]

    # One channel, one this.created, two members — no second create.
    assert length(events(cid)) == 1
    assert channel_row(cid)["member_count"] == 2
    assert channel_row(cid)["membership_version"] == 1

    # B's summary mirrors the peer (Alice).
    assert second["channel"]["title"] == "Alice"
    assert second["channel"]["dm_peer"]["user_id"] == @a
    # B's membership reflects B's OWN joined_at (set at create).
    assert is_binary(second["membership"]["joined_at"])
  end

  test "same pair resolves to the same channel from either direction (pair_key symmetry)" do
    seed_profile(@a, "Alice", nil)
    seed_profile(@b, "Bob", nil)

    {:ok, ab} = Dms.open(@a, "key-dm-sym1", %{"recipient_user_id" => @b})
    {:ok, ba} = Dms.open(@b, "key-dm-sym2", %{"recipient_user_id" => @a})

    assert ab["channel"]["channel_id"] == ba["channel"]["channel_id"]
  end

  # ----------------------------------------------------------- idempotency

  test "replay (same key + recipient) → identical response, no new rows" do
    seed_profile(@a, "Alice", nil)
    seed_profile(@b, "Bob", nil)

    {:ok, first} = Dms.open(@a, "key-dm-replay", %{"recipient_user_id" => @b})
    {:ok, second} = Dms.open(@a, "key-dm-replay", %{"recipient_user_id" => @b})

    assert first == second
  end

  test "same key, different recipient → 409 IDEMPOTENCY_CONFLICT" do
    seed_profile(@a, "Alice", nil)
    seed_profile(@b, "Bob", nil)
    seed_profile(@c, "Carol", nil)

    {:ok, _} = Dms.open(@a, "key-dm-conflict", %{"recipient_user_id" => @b})

    assert {:error, %{code: "IDEMPOTENCY_CONFLICT"}} =
             Dms.open(@a, "key-dm-conflict", %{"recipient_user_id" => @c})
  end

  # ------------------------------------------------------------- validation

  test "validation: missing / self / non-UUID / unknown recipient" do
    seed_profile(@a, "Alice", nil)
    seed_profile(@b, "Bob", nil)

    assert {:error, %{code: "INVALID_DM_TARGET"}} = Dms.open(@a, "k1", %{})

    assert {:error, %{code: "INVALID_DM_TARGET"}} =
             Dms.open(@a, "k2", %{"recipient_user_id" => @a})

    assert {:error, %{code: "INVALID_DM_TARGET"}} =
             Dms.open(@a, "k3", %{"recipient_user_id" => "not-a-uuid"})

    assert {:error, %{code: "DM_TARGET_NOT_FOUND"}} =
             Dms.open(@a, "k4", %{"recipient_user_id" => "11111111-2222-3333-4444-555555555555"})
  end

  # -------------------------------------------------------- last message

  test "existing DM open re-inflates: raw-text preview + real last_event_id" do
    seed_profile(@a, "Alice", nil)
    seed_profile(@b, "Bob", nil)

    {:ok, first} = Dms.open(@a, "key-dm-msg", %{"recipient_user_id" => @b})
    cid = first["channel"]["channel_id"]

    # A message lands in the DM after creation. The synthetic event_id sorts
    # after the writer-minted UUIDv7 (timestamp prefix) so it is the channel's
    # newest event.
    message_event = "99999999-9999-7999-8999-000000000002"
    seed_message("msg-dm-1", cid, @b, "hello from bob", event_id: message_event)

    # B opens (B's own key → a fresh projection, not a replay).
    {:ok, second} = Dms.open(@b, "key-dm-msg-b", %{"recipient_user_id" => @a})

    ch = second["channel"]
    # Old Worker getSummary parity: RAW text (no "Bob: " name prefix).
    assert ch["last_message_preview"] == "hello from bob"
    assert ch["last_message_at"] != nil
    assert ch["last_event_id"] == message_event
    assert ch["dm_peer"]["user_id"] == @a
  end

  # ------------------------------------------------------- wire filtering

  test "this.created is a bookkeeping row: absent from replay pages" do
    seed_profile(@a, "Alice", nil)
    seed_profile(@b, "Bob", nil)

    {:ok, first} = Dms.open(@a, "key-dm-wire", %{"recipient_user_id" => @b})
    cid = first["channel"]["channel_id"]

    # Gap recovery (§6.1b): the only stored event is this.created → empty,
    # but latest_event_id still reports the channel's real last event id.
    page = Timeline.channel_events(@a, cid, nil, 100)
    assert page[:events] == []
    assert page[:latest_event_id] == first["channel"]["last_event_id"]

    # Global replay (§10.3): same channel → no frames; a channel with no
    # wire frames is omitted from last_event_id_per_channel.
    global = Timeline.global_events(@a, [{cid, nil}])
    assert global[:items] == []
    assert Map.get(global[:last_event_id_per_channel], cid) == nil
  end
end
