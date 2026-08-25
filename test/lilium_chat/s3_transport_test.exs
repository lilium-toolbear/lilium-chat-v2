defmodule LiliumChat.S3.Transport.HttpcTest do
  @moduledoc """
  Real-transport tests for `LiliumChat.S3.Transport.Httpc` (issue #27).

  The only place in `mix test` that exercises the ACTUAL `:httpc` code path:
  a local `:httpd` (inets) server serves a deterministic object and
  `head/1` must see it. The presign/finalize conformance gate depends on
  this transport working in dev/conformance (contract §8.2 finalize HEAD);
  the unit-level `S3.head_object` tests use the injected `TestTransport`
  and would stay green even with a broken real transport.

  Regression covered: the pre-#27 transport called `:httpc.request/4` with
  `[]` as the Method (OTP 29 form is `request(Method, Request, HTTPOptions,
  Options)`), so EVERY head returned `{:error, :invalid_method}` — finalize
  was 415 against a real store even when the object existed.
  """

  use ExUnit.Case, async: false

  alias LiliumChat.S3

  # 15 bytes * 823 = exactly 12345 (contract §8.1 example size). The probe
  # server's HEAD answers with this size; the S3.head_object test verifies the
  # transport + match logic end to end against it.
  @payload :binary.copy("0123456789abcde", 823)
  @length byte_size(@payload)

  setup do
    # In this OTP build inets starts with its ebin directory missing from the
    # code path (lazily loaded modules such as :http_util fail with :nofile) —
    # the transport pins it back (same fix as `LiliumChat.DebugExport`).
    assert :ok = S3.Transport.Httpc.ensure_httpc_ready()

    # A minimal gen_tcp HTTP probe (request-line only, Connection: close) is
    # the server under test's peer: it keeps the test deterministic without
    # :httpd's document-root/log-file machinery.
    port = free_port()
    listener = start_http_probe(port)

    on_exit(fn -> :gen_tcp.close(listener) end)

    %{port: port}
  end

  test "head/1 returns 200 + content headers for an existing object", %{port: port} do
    assert {:ok, 200, headers} = S3.Transport.Httpc.head("http://127.0.0.1:#{port}/object.png")
    assert header(headers, "content-length") == Integer.to_string(@length)
    assert header(headers, "content-type") == "image/png"
  end

  test "head/1 returns 404 for a missing object", %{port: port} do
    assert {:ok, 404, _headers} = S3.Transport.Httpc.head("http://127.0.0.1:#{port}/missing.png")
  end

  test "head/1 maps connection refused to {:error, _}", %{port: _port} do
    assert {:error, _reason} = S3.Transport.Httpc.head("http://127.0.0.1:1/object.png")
  end

  test "S3.head_object verifies Content-Type + Content-Length via the real transport", %{
    port: port
  } do
    cfg =
      %S3.Config{
        access_key_id: "k",
        secret_access_key: "s",
        region: "us-east-1",
        endpoint: "http://127.0.0.1:#{port}",
        bucket: "lilium-chat-attachments",
        public_base: "http://127.0.0.1:#{port}",
        ttl_seconds: 300,
        transport: S3.Transport.Httpc
      }

    assert %{ok: true, content_type: "image/png", content_length: @length} =
             S3.head_object(cfg, "object.png", "image/png", @length)

    refute S3.head_object(cfg, "object.png", "image/png", 1).ok
    refute S3.head_object(cfg, "missing.png", "image/png", @length).ok
  end

  # ---------------------------------------------------------------- helpers

  # gen_tcp probe server: answers HEAD /object.png with 200 + the exact
  # content headers, everything else 404. One handler process per
  # connection; `Connection: close` keeps :httpc's connection handling dumb.
  defp start_http_probe(port) do
    {:ok, listener} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    spawn(fn -> http_probe_accept(listener) end)
    listener
  end

  defp http_probe_accept(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> http_probe_handle(socket) end)
        http_probe_accept(listener)

      {:error, _} ->
        :ok
    end
  end

  defp http_probe_handle(socket) do
    request_line =
      :gen_tcp.recv(socket, 0, 5_000)
      |> case do
        {:ok, data} -> data
        _ -> ""
      end
      |> String.split("\r\n", parts: 2)
      |> Enum.at(0, "")

    [_method, path | _] = String.split(request_line, " ")
    respond_http_probe(socket, path)
    :gen_tcp.close(socket)
  end

  defp respond_http_probe(socket, "/object.png") do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: image/png\r\n" <>
        "Content-Length: #{Integer.to_string(@length)}\r\n" <>
        "Connection: close\r\n\r\n"
    )
  end

  defp respond_http_probe(socket, _path) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 404 Not Found\r\n" <>
        "Content-Type: application/xml\r\n" <>
        "Content-Length: 9\r\n" <>
        "Connection: close\r\n\r\n"
    )
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {field, value} ->
        if String.downcase(to_string(field)) == name, do: to_string(value)
    end)
  end

  defp free_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    port
  end
end
