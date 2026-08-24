defmodule LiliumChat.ObservabilityTest do
  @moduledoc """
  Observability wiring tests (spec §10 key metrics, issue #21): the timed
  PubSub broadcast wrapper, the runtime gauges (WS connections / PubSub
  subscribers / active streams), the socket tracker, and the idempotency
  conflict counter.
  """

  use ExUnit.Case, async: false

  alias LiliumChat.{Errors, Observability}

  @test_id_prefix "obs-test"

  setup do
    # Capture the telemetry events under test with a process-local handler.
    events = [
      [:lilium_chat, :pubsub, :broadcast, :stop],
      [:lilium_chat, :websocket, :connections],
      [:lilium_chat, :pubsub, :subscribers],
      [:lilium_chat, :pubsub, :topics],
      [:lilium_chat, :pubsub, :subscribers_per_topic],
      [:lilium_chat, :streams, :active],
      [:lilium_chat, :idempotency, :conflict]
    ]

    parent = self()

    for {event, index} <- Enum.with_index(events) do
      handler = fn _event, measurements, metadata, _config ->
        send(parent, {:telemetry_capture, event, measurements, metadata})
        :ok
      end

      :telemetry.attach("#{@test_id_prefix}-#{index}", event, handler, nil)
    end

    on_exit(fn ->
      for index <- 0..(length(events) - 1) do
        :telemetry.detach("#{@test_id_prefix}-#{index}")
      end
    end)

    :ok
  end

  describe "broadcast/3 (PubSub 广播延迟)" do
    test "times Phoenix.PubSub.broadcast and returns its result" do
      assert :ok = Observability.broadcast(LiliumChat.PubSub, "topic:#{uniq()}", :payload)

      assert_receive {:telemetry_capture, [:lilium_chat, :pubsub, :broadcast, :stop],
                      %{duration: duration}, %{}}

      assert is_integer(duration) and duration >= 0
    end
  end

  describe "runtime_gauges/0" do
    test "emits the WS connection gauge per transport" do
      Observability.runtime_gauges()

      for transport <- ["browser", "bot", "bot_stream"] do
        assert_receive {:telemetry_capture, [:lilium_chat, :websocket, :connections],
                        %{count: count}, %{transport: ^transport}}

        assert is_integer(count) and count >= 0
      end
    end

    test "emits pubsub subscriber gauges for the live subscriptions" do
      :ok = Phoenix.PubSub.subscribe(LiliumChat.PubSub, "#{@test_id_prefix}:a")
      :ok = Phoenix.PubSub.subscribe(LiliumChat.PubSub, "#{@test_id_prefix}:b")

      Observability.runtime_gauges()

      assert_receive {:telemetry_capture, [:lilium_chat, :pubsub, :subscribers], %{count: total},
                      %{}}

      assert total >= 2

      assert_receive {:telemetry_capture, [:lilium_chat, :pubsub, :topics], %{count: topics}, %{}}

      assert topics >= 2

      assert_receive {:telemetry_capture, [:lilium_chat, :pubsub, :subscribers_per_topic],
                      %{count: per_topic}, %{}}

      assert per_topic >= 1
    end

    test "emits the active-streams gauge" do
      {:ok, _} = Registry.register(LiliumChat.Streams.Registry, {uniq(), uniq()}, nil)

      Observability.runtime_gauges()

      assert_receive {:telemetry_capture, [:lilium_chat, :streams, :active], %{count: count}, %{}}
      assert count >= 1
    end
  end

  describe "SocketTracker (WS 连接数)" do
    test "counts a socket process and decrements on its death" do
      pid =
        spawn(fn ->
          Observability.track_socket(:browser)

          receive do
            :stop -> :ok
          end
        end)

      eventually(fn -> Observability.SocketTracker.counts()[:browser] == 1 end)

      send(pid, :stop)
      eventually(fn -> Observability.SocketTracker.counts()[:browser] == 0 end)
    end
  end

  describe "idempotency conflict counter" do
    test "IDEMPOTENCY_CONFLICT construction emits the counter event" do
      _ = Errors.new("IDEMPOTENCY_CONFLICT")

      assert_receive {:telemetry_capture, [:lilium_chat, :idempotency, :conflict], %{count: 1},
                      %{}}
    end

    test "other error codes do not emit it" do
      _ = Errors.new("CHANNEL_NOT_FOUND")

      refute_receive {:telemetry_capture, [:lilium_chat, :idempotency, :conflict], _, _}, 50
    end
  end

  # ---------------------------------------------------------------- helpers

  defp uniq, do: LiliumChat.Ids.uuidv7()

  defp eventually(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      if tries == 0 do
        flunk("condition not reached in time")
      else
        Process.sleep(20)
        eventually(fun, tries - 1)
      end
    end
  end
end
