defmodule MaveCli.UploadChannel do
  @moduledoc false
  use WebSockex

  @socket "wss://dash.mave.io/api/v1/socket"
  @heartbeat_interval 25_000

  def start(token, owner \\ self(), opts \\ []) do
    socket = Keyword.get(opts, :socket, @socket)

    url =
      "#{String.trim_trailing(socket, "/")}/websocket?token=#{URI.encode_www_form(token)}&vsn=2.0.0"

    state = %{
      token: token,
      topic: "embed:#{token}",
      owner: owner,
      ref: 1,
      closing?: false
    }

    options = [extra_headers: [{"user-agent", "mave-cli/#{MaveCli.version()}"}]]
    WebSockex.start(url, __MODULE__, state, options ++ tls_options(socket, opts))
  end

  defp tls_options(socket, opts) do
    case URI.parse(socket) do
      %URI{scheme: scheme, host: host} when scheme in ["wss", "https"] ->
        [
          ssl_options: [
            verify: :verify_peer,
            cacerts: Keyword.get_lazy(opts, :cacerts, &:public_key.cacerts_get/0),
            server_name_indication: String.to_charlist(host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]

      _ ->
        []
    end
  end

  def close(pid), do: WebSockex.cast(pid, :close)

  @impl true
  def handle_connect(_conn, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    send(self(), :join)
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, message}, state) do
    case Jason.decode(message) do
      {:ok, [_join_ref, _ref, topic, event, payload]} ->
        handle_event(topic, event, payload, state)

      {:ok, %{"topic" => topic, "event" => event, "payload" => payload}} ->
        handle_event(topic, event, payload, state)

      _ ->
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast(:close, state), do: {:close, %{state | closing?: true}}

  @impl true
  def handle_info(:join, state) do
    {:reply, frame(state, state.ref, state.topic, "phx_join", %{}), %{state | ref: state.ref + 1}}
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    next_state = %{state | ref: state.ref + 1}
    {:reply, frame(state, nil, "phoenix", "heartbeat", %{}), next_state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(status, state) do
    send(state.owner, {:mave_upload, :disconnected, status.reason})
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    unless state.closing?, do: send(state.owner, {:mave_upload, :disconnected, reason})
    :ok
  end

  defp handle_event(topic, event, payload, state) when topic == state.topic do
    case event do
      "initiate" -> send(state.owner, {:mave_upload, :initiate, payload})
      "completed" -> send(state.owner, {:mave_upload, :completed, payload})
      "rendition" -> send(state.owner, {:mave_upload, :rendition, payload})
      "error" -> send(state.owner, {:mave_upload, :error, payload})
      "phx_reply" -> handle_reply(payload, state.owner)
      "phx_error" -> send(state.owner, {:mave_upload, :error, payload})
      "phx_close" -> send(state.owner, {:mave_upload, :disconnected, :channel_closed})
      _ -> :ok
    end

    {:ok, state}
  end

  defp handle_event(_topic, _event, _payload, state), do: {:ok, state}

  defp handle_reply(%{"status" => "error", "response" => response}, owner),
    do: send(owner, {:mave_upload, :error, response})

  defp handle_reply(_payload, _owner), do: :ok

  defp frame(state, join_ref, topic, event, payload) do
    join_ref = if is_integer(join_ref), do: Integer.to_string(join_ref), else: join_ref

    Jason.encode!([
      join_ref,
      Integer.to_string(state.ref),
      topic,
      event,
      payload
    ])
    |> then(&{:text, &1})
  end
end
