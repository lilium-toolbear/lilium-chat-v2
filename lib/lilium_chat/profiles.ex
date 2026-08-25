defmodule LiliumChat.Profiles do
  @moduledoc """
  ToolBear profile resolver (contract §3.1 / spec §4 D16 / A10).

  Resolves `user_id`s to display name + avatar against `public.users` on the
  same PG instance, in batches of 50 (read-only, bounded). Returns
  `%{user_id => %{display_name: ..., avatar_url: ...}}`; missing users are absent
  from the map (callers fall back to `Projections.fallback_display_name/1`).
  """

  alias LiliumChat.{Ids, Repo}

  @batch 50

  # Only UUID-shaped ids can match the `uuid` column; non-UUID ids (test
  # fixtures use bare strings such as "userws001") resolve to no profile.
  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc "Batch-resolve the given user ids (deduped) to a profile map."
  def resolve(user_ids) do
    unique = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if unique == [] do
      %{}
    else
      unique
      |> Enum.chunk_every(@batch)
      |> Enum.reduce(%{}, fn batch, acc ->
        # `user_id` is UUID-keyed in the production ToolBear table; the old
        # Worker casts its parameter to `uuid[]` (src/profile/resolve.ts) —
        # mirror the exact same predicate so both targets read identically
        # (a VARCHAR dev column type-errors against `$1::uuid[]`, issue #27).
        query = """
        SELECT user_id::text AS user_id, full_name, avatar_url
        FROM public.users
        WHERE user_id = ANY($1::uuid[])
        """

        # Postgrex encodes a `uuid[]` parameter only from 16-byte binaries
        # (a hyphenated string raises DBConnection.EncodeError), and only
        # UUID-shaped ids can match the column — drop the rest first.
        ids = Enum.filter(batch, fn id -> is_binary(id) and String.match?(id, @uuid_re) end)

        if ids == [] do
          acc
        else
          case Repo.query(query, [Enum.map(ids, &Ids.uuid_bytes/1)]) do
            {:ok, result} ->
              map =
                for row <- rows(result), into: %{} do
                  {row["user_id"],
                   %{
                     display_name: row["full_name"],
                     avatar_url: row["avatar_url"]
                   }}
                end

              Map.merge(acc, map)

            {:error, _} ->
              acc
          end
        end
      end)
    end
  end

  defp rows(%Postgrex.Result{rows: rows, columns: columns}) do
    for row <- rows do
      Map.new(Enum.zip(columns, row))
    end
  end

  defp rows(_), do: []
end
