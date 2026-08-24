defmodule LiliumChat.Components do
  @moduledoc """
  Message component validation (contract §3.8, old Worker `components.ts`
  parity, issue #19).

  Components ride on bot effects (`send_message` / `update_message` /
  pin drafts / pin patches) and on the Browser-visible Message projection.
  All validators return `{:ok, value}` / `{:error, reason}` — the reason is
  the `BOT_EFFECT_INVALID` message text.
  """

  @allowed_kinds ~w(button select radio checkbox checkbox_group text_input)
  @button_styles ~w(primary secondary danger)
  @interaction_policies ~w(multi per_user_once exclusive targeted)
  @uuidv7 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc "Validate a components array. Returns `{:ok, components}` or `{:error, reason}`."
  def validate(raw) when is_list(raw) do
    Enum.reduce_while(raw, {[], %{}}, fn item, {acc, seen} ->
      case validate_one(item, seen) do
        {:ok, component, seen} -> {:cont, {[component | acc], seen}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      # reduce_while returns the halted `{:error, reason}` on failure or the
      # final accumulator `{[component, ...], seen}` on completion
      # (reversed on the way out).
      {:error, reason} -> {:error, reason}
      {components, _seen} -> {:ok, Enum.reverse(components)}
    end
  end

  def validate(_raw), do: {:error, "components must be an array"}

  # Old Worker `rejectNonEmptyStreamComponents`.
  @doc "Stream messages must not include components."
  def reject_non_empty(components) when is_list(components) and components != [] do
    {:error, "stream messages must not include components"}
  end

  def reject_non_empty(_), do: :ok

  # Old Worker `disableComponentsInJson`: mark the matching component ids
  # `disabled: true`, leave everything else untouched.
  @doc "Return the components with `component_id in ids` marked `disabled: true`."
  def disable(components, ids) when is_list(components) do
    ids = MapSet.new(ids)

    for component <- components do
      if is_map(component) and Map.get(component, "component_id") in ids do
        Map.put(component, "disabled", true)
      else
        component
      end
    end
  end

  @doc """
  `platform:` custom_ids are reserved for the platform session-control pin
  (contract §3.10). Returns `:ok` or `{:error, reason}`.
  """
  def reject_platform_custom_ids(components) when is_list(components) do
    case Enum.find(components, fn component ->
           is_binary(Map.get(component, "custom_id")) and
             String.starts_with?(component["custom_id"], "platform:")
         end) do
      nil -> :ok
      _ -> {:error, "platform: custom_id is reserved"}
    end
  end

  def reject_platform_custom_ids(_), do: :ok

  # --------------------------------------------------------------- internals

  # Every check returns `{:ok, value}` / `{:error, field}`; the field name
  # becomes the error text suffix (old Worker messages are per-field).
  defp validate_one(item, seen) when is_map(item) do
    kind = item["kind"]
    component_id = item["component_id"]

    cond do
      not is_binary(kind) or kind not in @allowed_kinds ->
        {:error, "kind invalid"}

      not is_binary(component_id) or not Regex.match?(@uuidv7, component_id) ->
        {:error, "component_id must be UUIDv7"}

      Map.get(seen, component_id) ->
        {:error, "duplicate component_id in message"}

      true ->
        with {:ok, custom_id} <- non_empty_string(item, "custom_id"),
             {:ok, disabled} <- boolean(item, "disabled"),
             {:ok, policy_fields} <- interaction_policy(item),
             {:ok, kind_fields} <- kind_fields(kind, item) do
          {:ok,
           %{
             "kind" => kind,
             "component_id" => component_id,
             "custom_id" => custom_id,
             "disabled" => disabled
           }
           |> Map.merge(policy_fields)
           |> Map.merge(kind_fields), Map.put(seen, component_id, true)}
        end
    end
  end

  defp validate_one(_item, _seen), do: {:error, "component must be an object"}

  defp non_empty_string(item, key) do
    case item[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} required"}
    end
  end

  defp boolean(item, key) do
    case item[key] do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{key} must be boolean"}
    end
  end

  defp number(item, key) do
    case item[key] do
      value when is_integer(value) ->
        {:ok, value}

      value when is_float(value) ->
        # Pure-arithmetic finiteness check (Float.is_finite/1 only exists from
        # Elixir 1.21; we target 1.20): NaN fails `x - x == 0`; ±infinity fails
        # `x + 1.0 != x` (and inf - inf is NaN, caught by the first clause).
        if value - value == 0 and value + 1.0 != value do
          {:ok, value}
        else
          {:error, "#{key} must be a number"}
        end

      _ ->
        {:error, "#{key} must be a number"}
    end
  end

  defp in_set(item, key, set) do
    case item[key] do
      value when is_binary(value) ->
        if value in set do
          {:ok, value}
        else
          {:error, "#{key} invalid"}
        end

      _ ->
        {:error, "#{key} invalid"}
    end
  end

  defp kind_fields("button", item) do
    with {:ok, style} <- in_set(item, "style", @button_styles),
         {:ok, label} <- non_empty_string(item, "label") do
      {:ok, %{"style" => style, "label" => label}}
    end
  end

  defp kind_fields(kind, item) when kind in ["select", "radio"] do
    with {:ok, label} <- non_empty_string(item, "label"),
         {:ok, options} <- options(item, "options") do
      {:ok, %{"label" => label, "options" => options}}
    end
  end

  defp kind_fields("checkbox", item) do
    with {:ok, label} <- non_empty_string(item, "label"),
         {:ok, default_checked} <- boolean(item, "default_checked") do
      {:ok, %{"label" => label, "default_checked" => default_checked}}
    end
  end

  defp kind_fields("checkbox_group", item) do
    with {:ok, label} <- non_empty_string(item, "label"),
         {:ok, submit_label} <- non_empty_string(item, "submit_label"),
         {:ok, options} <- options(item, "options"),
         {:ok, min_selected} <- number(item, "min_selected"),
         {:ok, max_selected} <- number(item, "max_selected"),
         true <- min_selected <= max_selected do
      {:ok,
       %{
         "label" => label,
         "submit_label" => submit_label,
         "options" => options,
         "min_selected" => min_selected,
         "max_selected" => max_selected
       }}
    end
  end

  defp kind_fields("text_input", item) do
    with {:ok, label} <- non_empty_string(item, "label"),
         {:ok, multiline} <- boolean(item, "multiline"),
         {:ok, min_length} <- number(item, "min_length"),
         {:ok, max_length} <- number(item, "max_length"),
         {:ok, submit_label} <- non_empty_string(item, "submit_label"),
         true <- min_length <= max_length,
         {:ok, placeholder} <- optional_string(item, "placeholder") do
      {:ok,
       %{
         "label" => label,
         "multiline" => multiline,
         "min_length" => min_length,
         "max_length" => max_length,
         "submit_label" => submit_label
       }
       |> maybe_put("placeholder", placeholder)}
    end
  end

  defp kind_fields(_kind, _item), do: {:error, "kind invalid"}

  defp optional_string(item, key) do
    case item[key] do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp options(item, key) do
    case item[key] do
      list when is_list(list) and list != [] ->
        Enum.reduce_while(list, [], fn entry, acc ->
          if is_map(entry) do
            with {:ok, value} <- non_empty_string(entry, "value"),
                 {:ok, label} <- non_empty_string(entry, "label") do
              {:cont, [%{"value" => value, "label" => label} | acc]}
            else
              {:error, _reason} ->
                {:halt, {:error, "#{key} option invalid"}}
            end
          else
            {:halt, {:error, "#{key} option must be an object"}}
          end
        end)
        |> case do
          {:cont, entries} -> {:ok, Enum.reverse(entries)}
          {:halt, {:error, reason}} -> {:error, reason}
        end

      _ ->
        {:error, "#{key} required"}
    end
  end

  defp interaction_policy(item) do
    policy =
      case item["interaction_policy"] do
        value when is_binary(value) ->
          if value in @interaction_policies do
            {:ok, value}
          else
            {:error, "interaction_policy invalid"}
          end

        nil ->
          {:ok, nil}

        _ ->
          {:error, "interaction_policy invalid"}
      end

    target_user_id =
      case item["target_user_id"] do
        value when is_binary(value) ->
          if Regex.match?(@uuid, value) do
            {:ok, value}
          else
            {:error, "target_user_id invalid"}
          end

        nil ->
          {:ok, nil}

        _ ->
          {:error, "target_user_id invalid"}
      end

    with {:ok, policy} <- policy, {:ok, target_user_id} <- target_user_id do
      if policy == "targeted" and is_nil(target_user_id) do
        {:error, "target_user_id required when interaction_policy=targeted"}
      else
        fields =
          %{}
          |> maybe_put("interaction_policy", policy)
          |> maybe_put("target_user_id", target_user_id)

        {:ok, fields}
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
