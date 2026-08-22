defmodule LiliumChat.Profiles do
  @moduledoc """
  ToolBear profile resolver (contract §3.1 / spec §4 D16 / A10).

  Resolves `user_id`s to display name + avatar against `public.users` on the
  same PG instance, in batches of 50 (read-only, bounded). Returns
  `%{user_id => %{display_name: ..., avatar_url: ...}}`; missing users are absent
  from the map (callers fall back to `Projections.fallback_display_name/1`).
  """

  alias LiliumChat.Repo

  @batch 50

  @doc "Batch-resolve the given user ids (deduped) to a profile map."
  def resolve(user_ids) do
    unique = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if unique == [] do
      %{}
    else
      unique
      |> Enum.chunk_every(@batch)
      |> Enum.reduce(%{}, fn batch, acc ->
        query = """
        SELECT user_id::text AS user_id, full_name, avatar_url
        FROM public.users
        WHERE user_id = ANY($1)
        """

        case Repo.query(query, [batch]) do
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
