defmodule LiliumChat.CommandOptionsTest do
  @moduledoc """
  Unit tests for catalog command validation + canonical forms (issue #16,
  old `command-options.ts`).
  """

  use ExUnit.Case

  alias LiliumChat.{CanonicalJSON, CommandOptions}

  defp command(input), do: Map.merge(base_command(), input)

  defp base_command do
    %{
      "name" => "roll",
      "aliases" => ["d"],
      "description" => "Roll a dice",
      "help_text" => "roll [sides]",
      "options" => [
        %{"name" => "sides", "type" => "integer", "required" => false, "min" => 2, "max" => 100}
      ],
      "default_member_permission" => "member",
      "execution" => %{"mode" => "stateless"}
    }
  end

  describe "validate_command/1" do
    test "valid command" do
      assert {:ok, cmd} = CommandOptions.validate_command(command(%{}))
      assert cmd.name == "roll"
      assert cmd.aliases == ["d"]
      assert cmd.execution_mode == "stateless"
      assert cmd.stateful_config == nil

      assert hd(cmd.options) == [
               {"name", "sides"},
               {"type", "integer"},
               {"required", false},
               {"min", 2},
               {"max", 100}
             ]
    end

    test "name required" do
      assert {:error, "command.name required"} =
               CommandOptions.validate_command(command(%{"name" => nil}))

      assert {:error, "command.name required"} =
               CommandOptions.validate_command(command(%{"name" => ""}))
    end

    test "aliases: nil ok, non-list fails, duplicate (case-insensitive) fails" do
      assert {:ok, _} = CommandOptions.validate_command(command(%{"aliases" => nil}))

      assert {:error, "command.aliases must be array"} =
               CommandOptions.validate_command(command(%{"aliases" => "d"}))

      assert {:error, "duplicate alias: d"} =
               CommandOptions.validate_command(command(%{"aliases" => ["D", "d"]}))
    end

    test "description / help_text" do
      assert {:error, "command.description must be string"} =
               CommandOptions.validate_command(command(%{"description" => nil}))

      assert {:ok, cmd} = CommandOptions.validate_command(command(%{"help_text" => nil}))
      assert cmd.help_text == ""
    end

    test "options: seven types accepted" do
      for type <- ["string", "integer", "number", "boolean", "user", "channel", "role"] do
        assert {:ok, _} =
                 CommandOptions.validate_command(
                   command(%{"options" => [%{"name" => "x", "type" => type}]})
                 )
      end
    end

    test "options: invalid type rejected with JS String(value) in message" do
      assert {:error, "option.type invalid: array"} =
               CommandOptions.validate_command(
                 command(%{"options" => [%{"name" => "x", "type" => "array"}]})
               )

      assert {:error, "option.type invalid: null"} =
               CommandOptions.validate_command(command(%{"options" => [%{"name" => "x"}]}))
    end

    test "options: required must be boolean when present (null fails)" do
      assert {:error, "option.required must be boolean"} =
               CommandOptions.validate_command(
                 command(%{
                   "options" => [%{"name" => "x", "type" => "string", "required" => nil}]
                 })
               )
    end

    test "options: min/max only on integer|number" do
      assert {:error, "option.min/max only valid for integer|number, not string"} =
               CommandOptions.validate_command(
                 command(%{"options" => [%{"name" => "x", "type" => "string", "min" => nil}]})
               )

      assert {:error, "option.min > option.max"} =
               CommandOptions.validate_command(
                 command(%{
                   "options" => [%{"name" => "x", "type" => "integer", "min" => 5, "max" => 2}]
                 })
               )

      # present-but-null bounds on numeric types are skipped
      assert {:ok, _} =
               CommandOptions.validate_command(
                 command(%{"options" => [%{"name" => "x", "type" => "integer", "min" => nil}]})
               )
    end

    test "duplicate option name fails" do
      assert {:error, "duplicate option: x"} =
               CommandOptions.validate_command(
                 command(%{
                   "options" => [
                     %{"name" => "x", "type" => "string"},
                     %{"name" => "x", "type" => "string"}
                   ]
                 })
               )
    end

    test "permission validation" do
      assert {:ok, _} =
               CommandOptions.validate_command(command(%{"default_member_permission" => "admin"}))

      assert {:error, "default_member_permission must be member|admin|owner"} =
               CommandOptions.validate_command(
                 command(%{"default_member_permission" => "everyone"})
               )
    end

    test "stateful execution validates config" do
      stateful = %{
        "mode" => "stateful",
        "stateful" => %{
          "mutex_scope" => "channel",
          "default_ttl_seconds" => 30,
          "max_ttl_seconds" => 60,
          "listen_capability" => %{
            "message_types" => ["text"],
            "include_bot_messages" => false,
            "include_own_messages" => true
          }
        }
      }

      assert {:ok, cmd} = CommandOptions.validate_command(command(%{"execution" => stateful}))
      assert cmd.execution_mode == "stateful"
      assert is_list(cmd.stateful_config)
      assert {"mutex_scope", "channel"} in cmd.stateful_config

      assert {:error, "execution.stateful.mutex_scope must be channel"} =
               CommandOptions.validate_command(
                 command(%{
                   "execution" =>
                     Map.put(
                       stateful,
                       "stateful",
                       Map.put(stateful["stateful"], "mutex_scope", "bot")
                     )
                 })
               )
    end
  end

  describe "canonical forms" do
    test "canonical_definition sorts options and null-fills the six-field shape" do
      input =
        command(%{
          "options" => [
            %{"name" => "zeta", "type" => "string"},
            %{"name" => "alpha", "type" => "integer", "min" => 1}
          ]
        })

      assert {:ok, cmd} = CommandOptions.validate_command(input)
      canonical = CommandOptions.canonical_definition(cmd)
      encoded = CanonicalJSON.encode(canonical)

      assert encoded ==
               ~s({"options":[{"name":"alpha","type":"integer","required":false,"description":null,"min":1,"max":null},{"name":"zeta","type":"string","required":false,"description":null,"min":null,"max":null}],"description":"Roll a dice","help_text":"roll [sides]","default_member_permission":"member","execution_mode":"stateless","stateful_config":null})
    end

    test "command_request_hash is stable and name-sorted" do
      assert {:ok, a} = CommandOptions.validate_command(command(%{"name" => "b"}))
      assert {:ok, b} = CommandOptions.validate_command(command(%{"name" => "a"}))

      assert CommandOptions.command_request_hash([a, b]) ==
               CommandOptions.command_request_hash([b, a])

      assert CommandOptions.command_request_hash([a]) =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
