defmodule MaveCli.UploadTLSTest do
  use ExUnit.Case, async: true

  alias MaveCli.UploadChannel

  setup_all do
    {:ok, localhost: certificate(~c"localhost"), wrong_host: certificate(~c"other.example")}
  end

  @tag capture_log: true
  test "rejects an untrusted certificate before sending the upload token", %{localhost: config} do
    url = tls_server(config)
    assert {:error, error} = UploadChannel.start("synthetic-jwt", self(), socket: url)
    assert inspect(error) =~ "unknown_ca"
    assert_receive {:tls_handshake, {:error, _}}, 5_000
    refute_received {:upgrade_request, _}
  end

  @tag capture_log: true
  test "rejects a trusted certificate with the wrong hostname", %{wrong_host: config} do
    url = tls_server(config)

    assert {:error, error} =
             UploadChannel.start("synthetic-jwt", self(), socket: url, cacerts: config[:cacerts])

    assert inspect(error) =~ "hostname_check_failed"
    assert_receive {:tls_handshake, {:error, _}}, 5_000
    refute_received {:upgrade_request, _}
  end

  test "connects to a trusted certificate for the requested hostname", %{localhost: config} do
    url = tls_server(config)

    assert {:ok, channel} =
             UploadChannel.start("synthetic-jwt", self(), socket: url, cacerts: config[:cacerts])

    assert_receive {:tls_handshake, :ok}, 5_000
    assert_receive {:upgrade_request, request}, 5_000
    assert request =~ "token=synthetic-jwt"
    UploadChannel.close(channel)
  end

  # OTP creates ephemeral test certificates; no keys or live credentials are stored.
  defp certificate(host) do
    :public_key.pkix_test_data(%{
      root: [digest: :sha256, key: {:rsa, 2048, 65_537}],
      peer: [
        digest: :sha256,
        key: {:rsa, 2048, 65_537},
        extensions: [{:Extension, {2, 5, 29, 17}, false, [dNSName: host]}]
      ]
    })
  end

  defp tls_server(config) do
    {:ok, listener} =
      :ssl.listen(
        0,
        [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true] ++ config
      )

    {:ok, {_address, port}} = :ssl.sockname(listener)
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5_000)

        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} ->
            send(parent, {:tls_handshake, :ok})
            upgrade(socket, parent)

          {:error, _} = error ->
            send(parent, {:tls_handshake, error})
        end
      end)

    on_exit(fn ->
      :ssl.close(listener)
      Process.exit(server, :kill)
    end)

    "wss://localhost:#{port}/socket"
  end

  defp upgrade(socket, parent) do
    request = read_headers(socket, "")
    send(parent, {:upgrade_request, request})
    [_, key] = Regex.run(~r/sec-websocket-key:\s*([^\r\n]+)/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      :ssl.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      )

    receive do
      :stop -> :ok
    after
      5_000 -> :ok
    end

    :ssl.close(socket)
  end

  defp read_headers(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      received
    else
      {:ok, data} = :ssl.recv(socket, 0, 5_000)
      read_headers(socket, received <> data)
    end
  end
end
