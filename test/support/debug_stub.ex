defmodule LiliumChat.DebugStub do
  @moduledoc """
  Minimal raw-HTTP stub server for testing `LiliumChat.DebugExport` against
  the old Worker's `/internal/debug/sql-all` wire format (no new deps).

  The handler is a function `(path, body_binary) -> {status, response_body}`.
  Handles sequential requests until stopped.
  """

  def start_link(handler) do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    pid = spawn(fn -> accept_loop(lsock, handler) end)
    {:ok, %{port: port, pid: pid}}
  end

  def stop(%{pid: pid}) do
    Process.exit(pid, :kill)
    :ok
  end

  defp accept_loop(lsock, handler) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        handle_request(sock, handler)
        accept_loop(lsock, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_request(sock, handler) do
    try do
      {head, leftover} = read_head(sock, "")

      [method, path | _] =
        head |> to_string() |> String.split("\r\n") |> hd() |> String.split(" ")

      content_length = parse_content_length(head)
      body = read_body(sock, leftover, content_length)

      {status, response} = handler.(path, body)
      send_response(sock, status, response)
    rescue
      e ->
        IO.puts("[debug_stub] request failed: #{Exception.message(e)}")
        IO.puts(Exception.format_stacktrace(__STACKTRACE__))

        try do
          :gen_tcp.send(
            sock,
            "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
          )
        catch
          _, _ -> :ok
        end

        :gen_tcp.close(sock)
    end
  end

  # Reads until the header terminator, returning {head_bytes, leftover_bytes}.
  # The leftover is any body data that arrived in the same TCP segment.
  defp read_head(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        full = acc <> data

        if idx = find_delimiter(full) do
          {binary_part(full, 0, idx), binary_part(full, idx + 4, byte_size(full) - idx - 4)}
        else
          read_head(sock, full)
        end

      _ ->
        raise "debug stub: header read timed out with #{inspect(acc)}"
    end
  end

  defp find_delimiter(bin) do
    # :binary.match requires a binary pattern (a charlist is rejected).
    case :binary.match(bin, "\r\n\r\n") do
      {idx, _} -> idx
      :nomatch -> nil
    end
  end

  defp read_body(sock, leftover, content_length) when byte_size(leftover) >= content_length do
    binary_part(leftover, 0, content_length)
  end

  defp read_body(sock, leftover, content_length) do
    need = content_length - byte_size(leftover)
    {:ok, rest} = :gen_tcp.recv(sock, need, 10_000)
    leftover <> rest
  end

  defp parse_content_length(head) do
    head
    |> to_string()
    |> String.downcase()
    |> then(fn h ->
      case Regex.named_captures(~r/content-length:\s*(?<len>\d+)/, h) do
        %{"len" => len} -> String.to_integer(len)
        nil -> 0
      end
    end)
  end

  defp send_response(sock, status, response) do
    reason = if status == 200, do: "OK", else: "Error"

    raw =
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "content-type: application/json\r\n" <>
        "content-length: #{byte_size(response)}\r\n" <>
        "connection: close\r\n\r\n" <> response

    :gen_tcp.send(sock, raw)
    :timer.sleep(50)
    :gen_tcp.close(sock)
  end
end
