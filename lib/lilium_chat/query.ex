defmodule LiliumChat.Query do
  @moduledoc """
  Shared raw-SQL helpers for the read path (and other `Repo.query` callers).

  `rows/1` normalises a `Repo.query` result into a list of string-keyed row maps,
  the same shape every read-path query needs. Kept in one place so the
  Postgrex.Result → map conversion is not re-implemented per module.
  """

  @doc "Decode a `Repo.query` result into a list of `%{column => value}` row maps."
  def rows({:ok, %Postgrex.Result{rows: rows, columns: columns}}) do
    for row <- rows do
      Map.new(Enum.zip(columns, row))
    end
  end

  def rows({:ok, _other}), do: []
  def rows({:error, _}), do: []
end
