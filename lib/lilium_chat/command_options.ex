defmodule LiliumChat.CommandOptions do
  @moduledoc """
  Catalog command validation, canonical definitions and idempotency hashes
  (contract §9.3, issue #16).

  Port of the old Worker's `src/chat/command-options.ts`. The canonical forms
  feed two SHA-256 values that must byte-match the old implementation:

  * `definition_hash` — over `canonicalCommandDefinition` (fixed key order,
    missing option fields null-filled, options sorted by name);
  * the idempotency `request_hash` — over the validated command array
    (insertion key order, missing keys absent, commands sorted by name).

  A validated command is a map:

      %{
        name: String.t(),
        aliases: [String.t()],
        description: String.t(),
        help_text: String.t(),
        options: [[{key, value}]],          # insertion-ordered fields
        default_member_permission: "member" | "admin" | "owner",
        execution_mode: "stateless" | "stateful",
        stateful_config: nil | [canonical fields]
      }
  """

  alias LiliumChat.CanonicalJSON

  @option_types ~w(string integer number boolean user channel role)
  @permissions ~w(member admin owner)

  @doc """
  Validate one catalog command (§9.3 `validateCommand`). Returns
  `{:ok, command}` or `{:error, message}`.
  """
  def validate_command(input) when is_map(input) do
    with {:ok, name} <- name_check(input["name"]),
         {:ok, aliases} <- validate_aliases(input["aliases"], name),
         {:ok, description} <- validate_description(input["description"]),
         {:ok, help_text} <- validate_help_text(input["help_text"]),
         {:ok, options} <- validate_options(input["options"]),
         {:ok, perm} <- validate_permission(input),
         {:ok, {execution_mode, stateful_config}} <- validate_execution(input["execution"]) do
      {:ok,
       %{
         name: name,
         aliases: aliases,
         description: description,
         help_text: help_text,
         options: options,
         default_member_permission: perm,
         execution_mode: execution_mode,
         stateful_config: stateful_config
       }}
    end
  end

  # -- field validators (each returns {:ok, value} | {:error, msg}) ----------

  defp name_check(name) when is_binary(name) and name != "", do: {:ok, name}
  defp name_check(_), do: {:error, "command.name required"}

  # The JS validator keeps the *original* alias strings in `aliases` and only
  # lowercases for the dedup set (the command name, lowercased, is in the
  # set from the start).
  defp validate_aliases(nil, _name), do: {:ok, []}

  defp validate_aliases(aliases, name) when is_list(aliases) do
    validate_aliases_loop(aliases, MapSet.new([String.downcase(name)]), [])
  end

  defp validate_aliases(_aliases, _name), do: {:error, "command.aliases must be array"}

  defp validate_aliases_loop([alias | rest], seen, acc) do
    cond do
      not is_binary(alias) or alias == "" ->
        {:error, "alias must be non-empty string"}

      String.downcase(alias) in seen ->
        {:error, "duplicate alias: #{alias}"}

      true ->
        validate_aliases_loop(rest, MapSet.put(seen, String.downcase(alias)), [alias | acc])
    end
  end

  defp validate_aliases_loop([], _seen, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_description(description) when is_binary(description), do: {:ok, description}
  defp validate_description(_), do: {:error, "command.description must be string"}

  defp validate_help_text(nil), do: {:ok, ""}
  defp validate_help_text(help_text) when is_binary(help_text), do: {:ok, help_text}
  defp validate_help_text(_), do: {:error, "command.help_text must be string"}

  defp validate_options(nil), do: {:ok, []}

  defp validate_options(options) when is_list(options) do
    validate_options(options, MapSet.new(), [])
  end

  defp validate_options(_), do: {:error, "command.options must be array"}

  defp validate_options([option | rest], seen, acc) do
    case validate_option(option) do
      {:ok, fields, name} ->
        if name in seen do
          {:error, "duplicate option: #{name}"}
        else
          validate_options(rest, MapSet.put(seen, name), [fields | acc])
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_options([], _seen, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_permission(input) do
    perm = input["default_member_permission"] || "member"

    if is_binary(perm) and perm in @permissions do
      {:ok, perm}
    else
      {:error, "default_member_permission must be member|admin|owner"}
    end
  end

  defp validate_execution(execution) do
    cond do
      not is_map(execution) ->
        {:error, "command.execution must be object"}

      execution["mode"] == "stateless" ->
        {:ok, {"stateless", nil}}

      execution["mode"] == "stateful" ->
        validate_stateful(execution["stateful"])

      true ->
        {:error, "command.execution.mode must be stateless|stateful"}
    end
  end

  # Checks run sequentially in the exact order of the JS implementation; the
  # first failure wins.
  defp validate_stateful(stateful) do
    with :ok <- stateful_checks(stateful) do
      listen = stateful["listen_capability"]

      config =
        [
          {"mutex_scope", "channel"},
          {"default_ttl_seconds", stateful["default_ttl_seconds"]},
          {"max_ttl_seconds", stateful["max_ttl_seconds"]},
          {"listen_capability",
           [
             {"message_types", listen["message_types"]},
             {"include_bot_messages", listen["include_bot_messages"]},
             {"include_own_messages", listen["include_own_messages"]}
           ]}
        ]

      {:ok, {"stateful", config}}
    end
  end

  # Returns :ok or {:error, message} for the first failing check, in JS order.
  defp stateful_checks(stateful) do
    cond do
      not is_map(stateful) ->
        {:error, "command.execution.stateful required when mode=stateful"}

      stateful["mutex_scope"] != "channel" ->
        {:error, "execution.stateful.mutex_scope must be channel"}

      not positive_number?(stateful["default_ttl_seconds"]) ->
        {:error, "execution.stateful.default_ttl_seconds must be positive number"}

      not positive_number?(stateful["max_ttl_seconds"]) ->
        {:error, "execution.stateful.max_ttl_seconds must be positive number"}

      stateful["default_ttl_seconds"] > stateful["max_ttl_seconds"] ->
        {:error, "execution.stateful.default_ttl_seconds must be <= max_ttl_seconds"}

      not is_map(stateful["listen_capability"]) ->
        {:error, "execution.stateful.listen_capability must be object"}

      not string_list?(stateful["listen_capability"]["message_types"]) ->
        {:error, "execution.stateful.listen_capability.message_types must be string[]"}

      not is_boolean(stateful["listen_capability"]["include_bot_messages"]) ->
        {:error, "execution.stateful.listen_capability.include_bot_messages must be boolean"}

      not is_boolean(stateful["listen_capability"]["include_own_messages"]) ->
        {:error, "execution.stateful.listen_capability.include_own_messages must be boolean"}

      true ->
        :ok
    end
  end

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp positive_number?(value), do: is_number(value) and value > 0

  # -- option validation ------------------------------------------------------

  # Returns {:ok, fields, name} where fields is the insertion-ordered
  # {key, value} list exactly as JS builds the CommandOption object:
  # name, type, then (in order) required / description / min / max when
  # present.
  defp validate_option(raw) do
    if not is_map(raw) do
      {:error, "option must be an object"}
    else
      with {:ok, name} <- option_name(raw["name"]),
           {:ok, type} <- option_type(raw["type"]),
           {:ok, required_fields} <- option_required(raw),
           {:ok, description_fields} <- option_description(raw),
           {:ok, bound_fields} <- option_bounds(raw, type) do
        fields =
          [{"name", name}, {"type", type}] ++
            required_fields ++ description_fields ++ bound_fields

        {:ok, fields, name}
      end
    end
  end

  defp option_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp option_name(_), do: {:error, "option.name required"}

  defp option_type(type) do
    if is_binary(type) and type in @option_types do
      {:ok, type}
    else
      {:error, "option.type invalid: #{js_string(type)}"}
    end
  end

  # JS `String(value)` for error messages: strings verbatim, null → "null",
  # booleans → "true"/"false", numbers → decimal, anything else inspected.
  defp js_string(nil), do: "null"
  defp js_string(value) when is_binary(value), do: value
  defp js_string(true), do: "true"
  defp js_string(false), do: "false"
  defp js_string(value) when is_integer(value), do: Integer.to_string(value)
  defp js_string(value) when is_float(value), do: Float.to_string(value)
  defp js_string(value), do: inspect(value)

  # A present-but-null `required` fails (JS: `typeof null !== "boolean"`); an
  # absent key contributes no field.
  defp option_required(raw) do
    if Map.has_key?(raw, "required") do
      value = raw["required"]

      if is_boolean(value) do
        {:ok, [{"required", value}]}
      else
        {:error, "option.required must be boolean"}
      end
    else
      {:ok, []}
    end
  end

  defp option_description(raw) do
    case raw["description"] do
      nil ->
        {:ok, []}

      value when is_binary(value) ->
        {:ok, [{"description", value}]}

      _ ->
        {:error, "option.description must be string"}
    end
  end

  # min/max are only legal on integer|number options; a present-but-null value
  # is skipped for numeric types but still trips the "only valid for
  # integer|number" check on other types.
  defp option_bounds(raw, type) do
    if type in ["integer", "number"] do
      with {:ok, min_value, min_fields} <- option_bound(raw, "min"),
           {:ok, max_value, max_fields} <- option_bound(raw, "max") do
        if min_value != nil and max_value != nil and min_value > max_value do
          {:error, "option.min > option.max"}
        else
          {:ok, min_fields ++ max_fields}
        end
      end
    else
      if Map.has_key?(raw, "min") or Map.has_key?(raw, "max") do
        {:error, "option.min/max only valid for integer|number, not #{type}"}
      else
        {:ok, []}
      end
    end
  end

  defp option_bound(raw, key) do
    case raw[key] do
      nil ->
        {:ok, nil, []}

      value when is_number(value) ->
        {:ok, value, [{key, value}]}

      _ ->
        {:error, "option.#{key} must be number"}
    end
  end

  # -- canonical forms ---------------------------------------------------------

  @doc """
  `canonicalCommandDefinition` — fixed key order, options sorted by name and
  null-filled to the six-field shape.
  """
  def canonical_definition(cmd) do
    [
      {"options",
       cmd.options
       |> Enum.sort_by(&fetch_field(&1, "name"))
       |> Enum.map(fn fields ->
         [
           {"name", fetch_field(fields, "name")},
           {"type", fetch_field(fields, "type")},
           {"required", fetch_field(fields, "required", false)},
           {"description", fetch_field(fields, "description")},
           {"min", fetch_field(fields, "min")},
           {"max", fetch_field(fields, "max")}
         ]
       end)},
      {"description", cmd.description},
      {"help_text", cmd.help_text},
      {"default_member_permission", cmd.default_member_permission},
      {"execution_mode", cmd.execution_mode},
      {"stateful_config", cmd.stateful_config}
    ]
  end

  @doc """
  The idempotency `request_hash` for a catalog sync: SHA-256 over the
  canonical JSON of `{"commands": [...]}` with commands sorted by name and
  option fields in insertion order (JS `{...o}` spread order).
  """
  def command_request_hash(commands) do
    commands
    |> Enum.map(fn cmd ->
      [
        {"name", cmd.name},
        {"aliases", cmd.aliases},
        {"description", cmd.description},
        {"help_text", cmd.help_text},
        {"options", cmd.options},
        {"default_member_permission", cmd.default_member_permission},
        {"execution_mode", cmd.execution_mode},
        {"stateful_config", cmd.stateful_config}
      ]
    end)
    |> Enum.sort_by(fn fields -> fetch_field(fields, "name") end)
    |> then(&[{"commands", &1}])
    |> CanonicalJSON.encode_and_sha256()
  end

  defp fetch_field(fields, key), do: fetch_field(fields, key, nil)

  defp fetch_field(fields, key, default) do
    case List.keyfind(fields, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end
end
