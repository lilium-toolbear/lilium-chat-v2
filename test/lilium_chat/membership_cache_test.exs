defmodule LiliumChat.MembershipCacheTest do
  @moduledoc """
  ETS membership-version cache tests (spec D8 / §5.2, issue #8).

  Verifies the gate_check/2 semantics:
  * no cache entry → :deliver (first event)
  * mv_at_event == cached → :deliver (fast path)
  * mv_at_event < cached → :deliver (stale, shouldn't happen)
  * mv_at_event > cached → :recheck (gate re-check needed)
  """

  use ExUnit.Case

  alias LiliumChat.MembershipCache

  setup do
    # Ensure the ETS table exists (started by the app supervisor in test env)
    # For isolated tests, we use a unique table name via a fresh GenServer
    {:ok, _} = MembershipCache.start_link(name: :test_membership_cache)
    :ok
  end

  test "get/1 returns nil for uncached channel" do
    assert MembershipCache.get("ch-unknown") == nil
  end

  test "put/2 + get/1 roundtrip" do
    MembershipCache.put("ch-001", 42)
    assert MembershipCache.get("ch-001") == 42
  end

  test "invalidate/1 removes the cache entry" do
    MembershipCache.put("ch-001", 42)
    MembershipCache.invalidate("ch-001")
    assert MembershipCache.get("ch-001") == nil
  end

  test "gate_check: no cache entry → :deliver" do
    assert MembershipCache.gate_check("ch-unknown", 5) == :deliver
  end

  test "gate_check: mv_at_event == cached → :deliver" do
    MembershipCache.put("ch-001", 10)
    assert MembershipCache.gate_check("ch-001", 10) == :deliver
  end

  test "gate_check: mv_at_event < cached → :deliver" do
    MembershipCache.put("ch-001", 10)
    assert MembershipCache.gate_check("ch-001", 5) == :deliver
  end

  test "gate_check: mv_at_event > cached → :recheck" do
    MembershipCache.put("ch-001", 10)
    assert MembershipCache.gate_check("ch-001", 11) == :recheck
  end

  test "gate_check: recheck after put updates the cache" do
    MembershipCache.put("ch-001", 10)

    # First event with mv=11 triggers recheck
    assert MembershipCache.gate_check("ch-001", 11) == :recheck

    # After recheck, we update the cache
    MembershipCache.put("ch-001", 11)

    # Now mv=11 matches → deliver
    assert MembershipCache.gate_check("ch-001", 11) == :deliver
  end

  test "multiple channels are independent" do
    MembershipCache.put("ch-001", 1)
    MembershipCache.put("ch-002", 100)

    assert MembershipCache.gate_check("ch-001", 1) == :deliver
    assert MembershipCache.gate_check("ch-001", 2) == :recheck
    assert MembershipCache.gate_check("ch-002", 100) == :deliver
    assert MembershipCache.gate_check("ch-002", 101) == :recheck
  end
end
