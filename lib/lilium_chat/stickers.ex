defmodule LiliumChat.Stickers do
  @moduledoc """
  Personal sticker library read path (contract §8.3, issue #7).

  `GET /api/chat/stickers?limit=&cursor=` lists the caller's personal
  stickers, `created_at DESC`, keyset-paged by `created_at`. Pure read (A12):
  one statement.

  Semantics mirror the old Worker (`listStickersHandler` +
  `UserDirectory.listStickers`):

  * only the caller's rows, `deleted_at IS NULL`;
  * cursor = the raw `created_at` ISO of the last item (strictly-less-than
    keyset; the old Worker uses the raw stored ISO string as the cursor);
  * `next_cursor` is the last item's `created_at` whenever the page is
    non-empty (the old Worker does not null it out on short pages — the
    client simply receives an empty follow-up page), else null;
  * each item is `sticker_id` + the canonical `attachment` projection
    (`attachment_id`, `url`, `mime_type`, `width`, `height`, `size_bytes`,
    `blurhash`) + `created_at`.
  """

  alias LiliumChat.Projections
  alias LiliumChat.Query
  alias LiliumChat.Repo

  @doc """
  List the caller's personal stickers page.

  `opts`: `:limit` (already clamped 1..100 by the controller; default 50),
  `:cursor` (opaque string or nil). Returns
  `%{items: [...], next_cursor: string | nil}`.
  """
  def list_for_user(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    cursor = decode_cursor(Keyword.get(opts, :cursor))
    {cursor_clause, params} = cursor_clause(cursor)

    rows =
      Repo.query(
        """
        SELECT sticker_id, attachment_id, url, mime_type, width, height,
               size_bytes, blurhash, created_at
        FROM chat_v2.personal_stickers
        WHERE user_id = $1 AND deleted_at IS NULL AND #{cursor_clause}
        ORDER BY created_at DESC
        LIMIT #{limit}
        """,
        [user_id | params],
        type: true
      )
      |> Query.rows()

    items = Enum.map(rows, &project_sticker_item/1)

    next_cursor =
      case items do
        [] -> nil
        [_ | _] -> NaiveDateTime.to_iso8601(List.last(rows)["created_at"])
      end

    %{items: items, next_cursor: next_cursor}
  end

  defp project_sticker_item(row) do
    %{
      "sticker_id" => row["sticker_id"],
      "created_at" => Projections.format_ts(row["created_at"]),
      "attachment" => %{
        "attachment_id" => row["attachment_id"],
        "url" => row["url"],
        "mime_type" => row["mime_type"],
        "width" => row["width"],
        "height" => row["height"],
        "size_bytes" => row["size_bytes"],
        "blurhash" => row["blurhash"]
      }
    }
  end

  # Keyset predicate: `TRUE` on the first page, `created_at < $2` on a
  # follow-up page. `limit` is clamped to 1..100 by the caller, so the
  # interpolated `LIMIT #{limit}` is safe.
  defp cursor_clause(nil), do: {"TRUE", []}
  defp cursor_clause(cursor), do: {"created_at < $2", [cursor]}

  # The old Worker passes the raw cursor string straight to SQL
  # (`created_at < ?`). Here we accept ISO timestamps (full-precision, as
  # this endpoint emits them); anything unparseable is treated as "no
  # cursor" (first page) — the closest sane behaviour to the old Worker's
  # untyped SQLite string comparison.
  defp decode_cursor(nil), do: nil

  defp decode_cursor(""), do: nil

  defp decode_cursor(cursor) do
    case NaiveDateTime.from_iso8601(cursor) do
      {:ok, ndt} -> ndt
      _ -> nil
    end
  end
end
