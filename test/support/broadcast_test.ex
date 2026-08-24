defmodule LiliumChat.BroadcastTest do
  @moduledoc """
  PubSub frame collector for writer-op tests (shared by the per-channel
  writer test files, issue #13 and its siblings).

  `subscribe/1` returns a Task that joins the `LiliumChat.PubSub` topic and
  reports readiness to the parent. Send `:go` to the Task's pid once the
  command under test has run — it then drains `{:broadcast, _topic, frame}`
  messages for a quiet window and `Task.await/1` returns the collected list.
  """

  @quiet_ms 500

  def subscribe(topic) do
    parent = self()

    Task.async(fn ->
      Phoenix.PubSub.subscribe(LiliumChat.PubSub, topic)
      send(parent, {:sub_ready, topic})

      receive do
        :go -> :going
      end

      collect_frames([])
    end)
  end

  def collect_frames(acc) do
    receive do
      {:broadcast, _topic, frame} -> collect_frames(acc ++ [frame])
    after
      @quiet_ms -> acc
    end
  end
end
