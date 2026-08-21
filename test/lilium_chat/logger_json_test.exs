defmodule LiliumChat.LoggerJSONTest do
  @moduledoc """
  JSON structured logging tests (spec D18 / §10, issue #3).

  Acceptance under test: **logs are structured JSON** — one object per line
  with time / severity / message / metadata, and `request_id` available in
  the metadata so lines correlate with the X-Request-Id response header
  (issue #2 handoff).
  """

  use ExUnit.Case, async: true

  require Logger

  test "config wires the default logger handler to the JSON Basic formatter" do
    [formatter: {LoggerJSON.Formatters.Basic, opts}] =
      Application.get_env(:logger, :default_handler)

    assert Keyword.get(opts, :metadata) == [:request_id]
  end

  test "the running default handler uses the JSON formatter (runtime check)" do
    {:ok, handler_config} = :logger.get_handler_config(:default)

    formatter =
      get_in(handler_config, [:config, :formatter]) || Map.get(handler_config, :formatter)

    assert {LoggerJSON.Formatters.Basic, opts} = formatter
    assert Keyword.get(opts, :metadata) == [:request_id]
  end

  test "the Basic formatter emits one JSON object per line with the expected fields" do
    # `msg` uses the OTP logger internal format ({:string, iodata}).
    line =
      LoggerJSON.Formatters.Basic.format(
        %{level: :info, meta: %{request_id: "req_test", pid: self()}, msg: {:string, "hello"}},
        metadata: [:request_id]
      )

    assert {:ok, json} = Jason.decode(IO.chardata_to_string(line))
    assert json["message"] == "hello"
    assert json["severity"] == "info"
    assert json["time"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    assert json["metadata"]["request_id"] == "req_test"
  end

  test "Logger emits JSON lines with request_id metadata through the formatter (integration)" do
    # The test env logs at :warning — emit at warning level so the line is not
    # filtered out before it reaches the handler.
    pid = self()
    marker = "json_capture_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(:json_capture_test, :logger_std_h, %{
        formatter: {LoggerJSON.Formatters.Basic, metadata: [:request_id]},
        config: %{type: {:device, pid}}
      })

    on_exit(fn -> :logger.remove_handler(:json_capture_test) end)

    Logger.warning(marker, request_id: "req_#{marker}")

    # The capture handler is global — other tests' log lines may arrive too;
    # keep receiving until our marker shows up.
    text = receive_marker_line(marker)

    assert {:ok, json} = Jason.decode(text)
    assert json["message"] == marker
    assert json["severity"] == "warning"
    assert json["time"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    assert json["metadata"]["request_id"] == "req_#{marker}"
  end

  # Acts as an io device: std_h writes lines via `io:put_chars/2`, which
  # sends `{:io_request, From, Tag, ...}` and WAITS for `{io_reply, Tag, _}`.
  # Every drained line must be answered or the handler blocks on it.
  defp receive_marker_line(marker, timeout \\ 5_000) do
    receive do
      {:io_request, from, tag, {:put_chars, :unicode, line}} ->
        send(from, {:io_reply, tag, {:ok, self()}})
        text = IO.chardata_to_string(line)

        if String.contains?(text, marker) do
          text
        else
          receive_marker_line(marker)
        end
    after
      timeout -> flunk("no JSON log line containing #{marker} was captured")
    end
  end
end
