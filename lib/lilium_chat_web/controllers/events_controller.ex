defmodule LiliumChatWeb.EventsController do
  @moduledoc """
  Channel/global event recovery routes (contract §6.1b / §10.3, issue #6).

  * `GET /api/chat/channels/{channel_id}/events` — per-channel gap recovery
    (`{ events, latest_event_id, next_cursor }`, §6.1b);
  * `GET /api/chat/events` — global replay across channels
    (`{ items, next_cursor, last_event_id_per_channel }`, §10.3). Accepts
    `?channel_id=&after_event_id=` or the per-channel `?cursors=<base64url>` map.

  Both are pure reads (A12).
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Channels
  alias LiliumChat.Timeline
  alias LiliumChatWeb.ErrorHandler

  def channel_index(conn, %{"channel_id" => channel_id} = params) do
    user_id = conn.assigns.identity.user_id
    after_event_id = params["after_event_id"] || ""
    limit = params["limit"] || "100"

    body = Timeline.channel_events(user_id, channel_id, after_event_id, limit)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  def index(conn, params) do
    user_id = conn.assigns.identity.user_id

    targets =
      if params["channel_id"] do
        [{params["channel_id"], params["after_event_id"] || ""}]
      else
        cursors = decode_cursors(params["cursors"])

        for channel_id <- Channels.my_channel_ids(user_id) do
          {channel_id, Map.get(cursors, channel_id, "")}
        end
      end

    body = Timeline.global_events(user_id, targets)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # `cursors` = base64url(JSON {channel_id: after_event_id}) (contract §10.3).
  defp decode_cursors(nil), do: %{}

  defp decode_cursors(param) do
    normalized = param |> String.replace("-", "+") |> String.replace("_", "/")
    padded = normalized <> String.duplicate("=", rem(4 - rem(byte_size(normalized), 4), 4))

    case Base.decode64(padded) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
