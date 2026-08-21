defmodule LiliumChat.MembershipCache do
  @moduledoc """
  ETS-backed per-channel membership-version cache (spec D8 / §5.2, issue #8).

  The single source of truth for membership is `channel_members` (SoT).
  This cache stores the `channels.membership_version` per channel so that
  the fanout gate can quickly decide whether to re-check `channel_members`:

  * On `session.live_start`, the socket loads the current `membership_version`
    for each active channel into this cache.
  * When a broadcast frame arrives carrying `membership_version_at_event`,
    the socket compares it against the cached value:
      - `mv_at_event == cached` → deliver (no membership change since cache)
      - `mv_at_event > cached`  → re-check `channel_members` (SoT) before
        delivering; update cache on success.
      - `mv_at_event < cached` → stale event (shouldn't happen with
        per-channel monotonic ordering)

  The cache is process-local (ETS :set table, public). It is volatile —
  on restart the socket re-loads from PG on the next `session.live_start`.
  """

  use GenServer

  @table :lilium_chat_membership_cache

  # ------------------------------------------------------------------ API

  @doc """
  Start the cache. Returns `{:ok, pid}`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Get the cached membership version for `channel_id`.

  Returns the integer version, or `nil` if not cached.
  """
  def get(channel_id) do
    case :ets.lookup(@table, channel_id) do
      [{^channel_id, version}] -> version
      [] -> nil
    end
  end

  @doc """
  Set the cached membership version for `channel_id`.
  """
  def put(channel_id, version) do
    :ets.insert(@table, {channel_id, version})
  end

  @doc """
  Invalidate (delete) the cache entry for `channel_id`.
  """
  def invalidate(channel_id) do
    :ets.delete(@table, channel_id)
  end

  @doc """
  Check if a channel's event should be delivered based on the cached
  membership version.

  Returns:
    * `:deliver` — `mv_at_event` matches or is older than cached (fast path)
    * `:recheck` — `mv_at_event` is newer than cached (gate re-check needed)
    * `:deliver` — no cache entry (first event for this channel)
  """
  def gate_check(channel_id, mv_at_event) do
    case get(channel_id) do
      nil ->
        :deliver

      cached when mv_at_event > cached ->
        :recheck

      _ ->
        :deliver
    end
  end

  # ----------------------------------------------------------- GenServer

  @impl GenServer
  def init(_opts) do
    if :ets.whereis(@table) != :undefined do
      :ets.info(@table)
    else
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])
    end

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    if :ets.whereis(@table) != :undefined do
      :ets.give_away(@table, self(), %{})
    end

    :ok
  end
end
