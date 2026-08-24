defmodule LiliumChat.Stream do
  @moduledoc """
  Per-stream process — `Stream.<channel_id>#<message_id>` (spec §2.2,
  contract §9.15, issue #18).

  Holds the ephemeral seq/ack buffer:

  * `ack_seq` — highest seq that has been durable-flushed (`flushed_text`)
  * `received_seq` — highest seq accepted on the **current** WS attachment
  * gap = `received_seq + 1`

  Finalize / abandon persist through the channel writer so the canonical
  `message.stream_finalized` / `message.stream_abandoned` events stay on
  the per-channel monotonic sequence. Live-only `stream_event` frames are
  broadcast on `channel:<id>` directly (not via `/deliver`).
  """

  use GenServer

  require Logger

  alias LiliumChat.{BotStream, BotStream.Seq, Channel, Errors, Query, Repo}
  alias LiliumChat.WebSockets.Frames

  # ---------------------------------------------------------------- lifecycle

  def child_spec(attrs) do
    %{
      id: {__MODULE__, {attrs.channel_id, attrs.message_id}},
      start: {__MODULE__, :start_link, [attrs]},
      type: :worker,
      restart: :temporary
    }
  end

  def start_link(attrs) do
    GenServer.start_link(__MODULE__, attrs, name: via(attrs.channel_id, attrs.message_id))
  end

  @doc """
  Start (or reuse) the stream process for a fresh `start_stream` effect.
  Returns `{:ok, stream_handle}` (`channel_id` / `message_id` / `ws_url` /
  `expires_at`).
  """
  def start_stream(channel_id, message_id, bot_id, message) when is_map(message) do
    now = DateTime.utc_now()

    attrs = %{
      channel_id: channel_id,
      message_id: message_id,
      bot_id: bot_id,
      message_type: message["type"] || "text",
      format: message["format"] || "plain",
      reply_to: message["reply_to_message_id"] || message["reply_to"],
      created_at: now,
      expires_at: parse_expires_at(message["expires_at"], now)
    }

    with {:ok, _pid} <- ensure_started(attrs) do
      {:ok, handle(attrs)}
    end
  end

  @doc "Ensure the stream process exists (lazy start). Returns `{:ok, pid}`."
  def ensure_started(attrs) do
    case DynamicSupervisor.start_child(LiliumChat.StreamConnections, child_spec(attrs)) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "Broadcast live-only `message.stream_started` on `channel:<id>`."
  def broadcast_started(channel_id, message_id) do
    frame =
      Frames.stream_event("message.stream_started", channel_id, %{
        "channel_id" => channel_id,
        "message_id" => message_id
      })

    broadcast_live(channel_id, frame)
    :ok
  end

  # ----------------------------------------------------------------- calls

  def attach(channel_id, message_id, channel_pid) do
    call(channel_id, message_id, {:attach, channel_pid})
  end

  def append(channel_id, message_id, seq, delta) do
    call(channel_id, message_id, {:append, seq, delta})
  end

  def flush(channel_id, message_id) do
    call(channel_id, message_id, :flush)
  end

  def finalize(channel_id, message_id, frame) when is_map(frame) do
    call(channel_id, message_id, {:finalize, frame}, 30_000)
  end

  def abandon(channel_id, message_id) do
    call(channel_id, message_id, :abandon, 30_000)
  end

  def debug_state(channel_id, message_id) do
    call(channel_id, message_id, :debug_state)
  end

  @doc "Owner bot_id for the live stream process, or `{:error, _}`."
  def owner(channel_id, message_id) do
    case debug_state(channel_id, message_id) do
      %{bot_id: bot_id} -> {:ok, bot_id}
      other -> other
    end
  end

  defp call(channel_id, message_id, msg, timeout \\ 5_000) do
    case pid_for(channel_id, message_id) || rehydrate_pid(channel_id, message_id) do
      nil ->
        {:error, Errors.new("BOT_STREAM_NOT_FOUND", "stream not active")}

      pid ->
        try do
          GenServer.call(pid, msg, timeout)
        catch
          :exit, _ -> {:error, Errors.new("BOT_STREAM_NOT_FOUND", "stream not active")}
        end
    end
  end

  # After finalize/abandon the process may have died; the messages row +
  # invocation_json is enough to revive it for idempotent replay.
  defp rehydrate_pid(channel_id, message_id) do
    case load_persisted(channel_id, message_id) do
      nil ->
        nil

      attrs ->
        {:ok, pid} = ensure_started(attrs)
        pid
    end
  end

  defp load_persisted(channel_id, message_id) do
    row =
      Query.rows(
        Repo.query(
          """
          SELECT sender_bot_id, stream_state, text, format, type, reply_to,
                 created_at, invocation_json
          FROM chat_v2.messages
          WHERE channel_id = $1 AND message_id = $2
            AND stream_state IN ('final', 'abandoned')
          """,
          [channel_id, message_id],
          type: true
        )
      )
      |> List.first()

    if row, do: attrs_from_row(channel_id, message_id, row)
  end

  defp attrs_from_row(channel_id, message_id, row) do
    inv = invocation_map(row["invocation_json"])
    stream = inv["stream"] || %{}

    status =
      case row["stream_state"] do
        "final" -> :finalized
        "abandoned" -> :abandoned
      end

    now = DateTime.utc_now()

    %{
      channel_id: channel_id,
      message_id: message_id,
      bot_id: row["sender_bot_id"],
      message_type: row["type"] || "text",
      format: row["format"] || "plain",
      reply_to: row["reply_to"],
      created_at: row["created_at"] || now,
      expires_at: now,
      status: status,
      flushed_text: row["text"] || "",
      finalize_request_hash: stream["finalize_request_hash"],
      finalized_response:
        if(status == :finalized and is_binary(stream["event_id"]),
          do: %{"message_id" => message_id, "event_id" => stream["event_id"]}
        ),
      abandoned_text_hash: stream["abandoned_text_hash"],
      abandoned_response:
        if(status == :abandoned and is_binary(stream["event_id"]),
          do: %{"message_id" => message_id, "event_id" => stream["event_id"]}
        )
    }
  end

  defp invocation_map(%{} = map), do: map

  defp invocation_map(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp invocation_map(_), do: %{}

  # --------------------------------------------------------- server callbacks

  @impl true
  def init(attrs) do
    status = Map.get(attrs, :status, :streaming)

    expire_ref =
      if status == :streaming do
        expire_ms = max(DateTime.diff(attrs.expires_at, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(self(), :expire, expire_ms)
      end

    Logger.debug("stream started: #{attrs.channel_id}##{attrs.message_id} (#{status})")

    {:ok,
     %{
       channel_id: attrs.channel_id,
       message_id: attrs.message_id,
       bot_id: attrs.bot_id,
       status: status,
       ack_seq: 0,
       received_seq: 0,
       flushed_text: Map.get(attrs, :flushed_text, ""),
       pending_text: "",
       pending_end_seq: 0,
       recent_unacked_hashes: %{},
       fanout_pending_text: "",
       fanout_end_seq: 0,
       expires_at: attrs.expires_at,
       created_at: attrs.created_at,
       message_type: attrs.message_type,
       format: attrs.format,
       reply_to: attrs.reply_to,
       finalize_request_hash: Map.get(attrs, :finalize_request_hash),
       finalized_response: Map.get(attrs, :finalized_response),
       abandoned_text_hash: Map.get(attrs, :abandoned_text_hash),
       abandoned_response: Map.get(attrs, :abandoned_response),
       attachment_pid: nil,
       expire_ref: expire_ref,
       flush_ref: nil,
       fanout_ref: nil
     }}
  end

  @impl true
  def handle_call({:attach, channel_pid}, _from, state) do
    state = reset_attachment(state, channel_pid)

    ready = %{
      channel_id: state.channel_id,
      message_id: state.message_id,
      expires_at: DateTime.to_iso8601(state.expires_at),
      ack_seq: state.ack_seq
    }

    {:reply, {:ok, ready}, state}
  end

  def handle_call({:append, seq, delta}, _from, state) do
    cond do
      state.status != :streaming ->
        {:reply, {:error, terminal_error(state)}, state}

      expired?(state) ->
        {:reply, {:error, Errors.new("BOT_STREAM_EXPIRED", "stream expired")}, state}

      true ->
        do_append(state, seq, delta)
    end
  end

  def handle_call(:flush, _from, state) do
    {state, ack_seq} = flush_pending(state, push?: true)
    {:reply, {:ok, ack_seq}, state}
  end

  def handle_call({:finalize, frame}, _from, state) do
    {reply, state} = do_finalize(state, frame)
    {:reply, reply, state}
  end

  def handle_call(:abandon, _from, state) do
    {reply, state} = do_abandon(state)
    {:reply, reply, state}
  end

  def handle_call(:debug_state, _from, state) do
    snapshot = %{
      status: state.status,
      bot_id: state.bot_id,
      ack_seq: state.ack_seq,
      received_seq: state.received_seq,
      flushed_text: state.flushed_text,
      pending_text: state.pending_text
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:expire, state) do
    {_reply, state} = do_abandon(state)
    {:noreply, state}
  end

  def handle_info(:flush_due, state) do
    {state, _} = flush_pending(%{state | flush_ref: nil}, push?: true)
    {:noreply, state}
  end

  def handle_info(:fanout_due, state) do
    state = fanout_pending(%{state | fanout_ref: nil})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --------------------------------------------------------------- append

  defp do_append(state, seq, delta) do
    case Seq.validate(seq, state.ack_seq, state.received_seq) do
      :durable_noop ->
        push_ack(state, state.ack_seq)
        {:reply, {:ok, {:durable_noop, state.ack_seq}}, state}

      :sequence_gap ->
        {:reply, {:error, Errors.new("BOT_STREAM_SEQUENCE_GAP", "append sequence gap")}, state}

      :unacked_duplicate ->
        hash = BotStream.hash_delta(delta)

        case Map.get(state.recent_unacked_hashes, seq) do
          ^hash ->
            {:reply, {:ok, :unacked_duplicate}, state}

          _ ->
            {:reply, {:error, Errors.new("BOT_STREAM_CONFLICT", "append conflict for seq")},
             state}
        end

      :accept ->
        hash = BotStream.hash_delta(delta)

        state = %{
          state
          | pending_text: state.pending_text <> delta,
            pending_end_seq: seq,
            received_seq: seq,
            recent_unacked_hashes: Map.put(state.recent_unacked_hashes, seq, hash),
            fanout_pending_text: state.fanout_pending_text <> delta,
            fanout_end_seq: seq
        }

        state = schedule_cadence(state)
        {:reply, {:ok, :accepted}, state}
    end
  end

  # ------------------------------------------------------------- finalize

  defp do_finalize(state, frame) do
    components = frame["components"] || frame[:components] || []
    attachment_ids = frame["attachment_ids"] || frame[:attachment_ids] || []
    final_seq = frame["final_seq"] || frame[:final_seq]

    cond do
      is_list(components) and components != [] ->
        {{:error,
          Errors.new("BOT_EFFECT_INVALID", "stream messages must not include components")}, state}

      is_list(attachment_ids) and attachment_ids != [] ->
        {{:error, Errors.new("BOT_EFFECT_INVALID", "attachment_ids not supported yet")}, state}

      state.status == :finalized ->
        replay_finalize(state, final_seq, attachment_ids)

      state.status != :streaming ->
        {{:error, Errors.new("BOT_STREAM_EXPIRED", "stream expired")}, state}

      expired?(state) ->
        {{:error, Errors.new("BOT_STREAM_EXPIRED", "stream expired")}, state}

      not is_integer(final_seq) ->
        {{:error, Errors.new("BOT_EFFECT_INVALID", "final_seq required")}, state}

      final_seq > state.received_seq ->
        {{:error, Errors.new("BOT_STREAM_SEQUENCE_GAP", "finalize sequence gap")}, state}

      final_seq < state.received_seq ->
        {{:error, Errors.new("BOT_STREAM_CONFLICT", "finalize sequence behind received")}, state}

      true ->
        commit_finalize(state, final_seq, attachment_ids)
    end
  end

  defp replay_finalize(state, final_seq, attachment_ids) do
    hash = BotStream.finalize_request_hash(final_seq, state.flushed_text, attachment_ids)

    if hash == state.finalize_request_hash and is_map(state.finalized_response) do
      {{:ok, state.finalized_response}, state}
    else
      {{:error,
        Errors.new("BOT_STREAM_CONFLICT", "stream already finalized with different request")},
       state}
    end
  end

  defp commit_finalize(state, final_seq, attachment_ids) do
    {state, _} = flush_pending(state, push?: false)
    state = fanout_pending(state)

    if state.ack_seq != state.received_seq or final_seq != state.received_seq do
      {{:error, Errors.new("BOT_STREAM_CONFLICT", "finalize before flush complete")}, state}
    else
      hash = BotStream.finalize_request_hash(final_seq, state.flushed_text, attachment_ids)

      input = %{
        bot_id: state.bot_id,
        message_id: state.message_id,
        resolved_text: state.flushed_text,
        finalize_request_hash: hash,
        final_seq: final_seq,
        created_at: state.created_at,
        format: state.format,
        type: state.message_type,
        reply_to: state.reply_to
      }

      case Channel.finalize_stream(state.channel_id, input) do
        {:ok, response} ->
          cancel_timers(state)

          state = %{
            state
            | status: :finalized,
              finalize_request_hash: hash,
              finalized_response: response,
              pending_text: "",
              fanout_pending_text: "",
              recent_unacked_hashes: %{}
          }

          {{:ok, response}, state}

        {:error, %Errors.ApiError{} = error} ->
          {{:error, error}, state}
      end
    end
  end

  # -------------------------------------------------------------- abandon

  defp do_abandon(state) do
    cond do
      state.status == :abandoned and is_nil(state.abandoned_response) ->
        {{:ok, :cleanup}, state}

      state.status == :abandoned and is_map(state.abandoned_response) ->
        {{:ok, state.abandoned_response}, state}

      state.status == :finalized ->
        {{:error, Errors.new("BOT_STREAM_CONFLICT", "stream already finalized")}, state}

      true ->
        {state, _} = flush_pending(state, push?: false)
        resolved = state.flushed_text

        if resolved == "" do
          cancel_timers(state)
          broadcast_cleanup(state)

          {{:ok, :cleanup},
           %{state | status: :abandoned, pending_text: "", fanout_pending_text: ""}}
        else
          input = %{
            bot_id: state.bot_id,
            message_id: state.message_id,
            resolved_text: resolved,
            created_at: state.created_at,
            format: state.format,
            type: state.message_type,
            reply_to: state.reply_to
          }

          case Channel.abandon_stream(state.channel_id, input) do
            {:ok, response} ->
              cancel_timers(state)

              state = %{
                state
                | status: :abandoned,
                  abandoned_text_hash: BotStream.text_hash(resolved),
                  abandoned_response: response,
                  pending_text: "",
                  fanout_pending_text: ""
              }

              {{:ok, response}, state}

            {:error, %Errors.ApiError{} = error} ->
              {{:error, error}, state}
          end
        end
    end
  end

  # -------------------------------------------------------- flush / fanout

  defp flush_pending(state, opts) do
    push? = Keyword.get(opts, :push?, true)

    if state.pending_text == "" do
      {state, state.ack_seq}
    else
      ack_seq = state.pending_end_seq

      hashes =
        state.recent_unacked_hashes
        |> Enum.reject(fn {seq, _} -> seq <= ack_seq end)
        |> Map.new()

      if state.flush_ref, do: Process.cancel_timer(state.flush_ref)

      state = %{
        state
        | flushed_text: state.flushed_text <> state.pending_text,
          ack_seq: ack_seq,
          pending_text: "",
          pending_end_seq: ack_seq,
          recent_unacked_hashes: hashes,
          flush_ref: nil
      }

      if push?, do: push_ack(state, ack_seq)
      {state, ack_seq}
    end
  end

  defp fanout_pending(state) do
    if state.fanout_pending_text == "" do
      state
    else
      if state.fanout_ref, do: Process.cancel_timer(state.fanout_ref)

      frame =
        Frames.stream_event(
          "message.stream_delta",
          state.channel_id,
          %{
            "channel_id" => state.channel_id,
            "message_id" => state.message_id,
            "delta" => state.fanout_pending_text
          },
          stream_seq: state.fanout_end_seq
        )

      broadcast_live(state.channel_id, frame)

      %{state | fanout_pending_text: "", fanout_end_seq: state.received_seq, fanout_ref: nil}
    end
  end

  defp schedule_cadence(state) do
    state
    |> schedule_flush()
    |> schedule_fanout()
  end

  defp schedule_flush(state) do
    cond do
      state.pending_text == "" ->
        state

      byte_size(state.pending_text) >= pending_flush_threshold() ->
        {state, _} = flush_pending(state, push?: true)
        state

      state.flush_ref ->
        state

      true ->
        ref = Process.send_after(self(), :flush_due, ack_flush_interval_ms())
        %{state | flush_ref: ref}
    end
  end

  defp schedule_fanout(state) do
    cond do
      state.fanout_pending_text == "" ->
        state

      byte_size(state.fanout_pending_text) >= fanout_max_pending_bytes() ->
        fanout_pending(state)

      state.fanout_ref ->
        state

      true ->
        ref = Process.send_after(self(), :fanout_due, fanout_interval_ms())
        %{state | fanout_ref: ref}
    end
  end

  # -------------------------------------------------------------- helpers

  defp reset_attachment(state, channel_pid) do
    %{
      state
      | attachment_pid: channel_pid,
        received_seq: state.ack_seq,
        pending_text: "",
        pending_end_seq: state.ack_seq,
        recent_unacked_hashes: %{},
        fanout_pending_text: "",
        fanout_end_seq: state.ack_seq
    }
  end

  defp push_ack(state, ack_seq) do
    if is_pid(state.attachment_pid) do
      send(state.attachment_pid, {:stream_push, BotStream.build_append_ack(ack_seq)})
    end

    :ok
  end

  defp broadcast_cleanup(state) do
    frame =
      Frames.stream_event("message.stream_abandon_cleanup", state.channel_id, %{
        "channel_id" => state.channel_id,
        "message_id" => state.message_id
      })

    broadcast_live(state.channel_id, frame)
  end

  defp broadcast_live(channel_id, frame) do
    topic = "channel:" <> channel_id
    Phoenix.PubSub.broadcast(LiliumChat.PubSub, topic, {:broadcast, topic, frame})
  end

  defp cancel_timers(state) do
    if state.expire_ref, do: Process.cancel_timer(state.expire_ref)
    if state.flush_ref, do: Process.cancel_timer(state.flush_ref)
    if state.fanout_ref, do: Process.cancel_timer(state.fanout_ref)
    :ok
  end

  defp expired?(state), do: DateTime.compare(DateTime.utc_now(), state.expires_at) != :lt

  defp terminal_error(%{status: :abandoned}),
    do: Errors.new("BOT_STREAM_EXPIRED", "stream expired")

  defp terminal_error(%{status: :expired}),
    do: Errors.new("BOT_STREAM_EXPIRED", "stream expired")

  defp terminal_error(%{status: :finalized}),
    do: Errors.new("BOT_STREAM_CONFLICT", "stream already finalized")

  defp terminal_error(_), do: Errors.new("BOT_STREAM_NOT_FOUND", "stream not active")

  defp handle(attrs) do
    %{
      "channel_id" => attrs.channel_id,
      "message_id" => attrs.message_id,
      "ws_url" => "/api/chat/bot/channels/#{attrs.channel_id}/streams/#{attrs.message_id}/ws",
      "expires_at" => DateTime.to_iso8601(attrs.expires_at)
    }
  end

  defp pid_for(channel_id, message_id) do
    case Registry.lookup(LiliumChat.Streams.Registry, {channel_id, message_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(channel_id, message_id) do
    {:via, Registry, {LiliumChat.Streams.Registry, {channel_id, message_id}}}
  end

  defp cfg, do: Application.get_env(:lilium_chat, :bot_stream, [])

  defp parse_expires_at(%DateTime{} = dt, _now), do: dt

  defp parse_expires_at(iso, now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.add(now, ttl_seconds(), :second)
    end
  end

  defp parse_expires_at(_other, now), do: DateTime.add(now, ttl_seconds(), :second)

  defp ttl_seconds, do: Keyword.get(cfg(), :ttl_seconds, 300)
  defp ack_flush_interval_ms, do: Keyword.get(cfg(), :ack_flush_interval_ms, 250)
  defp fanout_interval_ms, do: Keyword.get(cfg(), :fanout_interval_ms, 100)
  defp pending_flush_threshold, do: Keyword.get(cfg(), :pending_flush_threshold_bytes, 8_192)
  defp fanout_max_pending_bytes, do: Keyword.get(cfg(), :fanout_max_pending_bytes, 4_096)
end
