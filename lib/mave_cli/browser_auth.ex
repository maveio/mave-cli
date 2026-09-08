defmodule MaveCli.BrowserAuth do
  @moduledoc false

  @default_expires_in 600
  @default_interval 2

  def login(opts \\ []) do
    request = Keyword.get(opts, :request, &Req.request/1)
    base_url = Keyword.get(opts, :base_url) || Application.fetch_env!(:mave_cli, :api_base_url)

    case create_authorization(request, base_url, opts) do
      {:ok, authorization} -> authorize_in_browser(authorization, request, base_url, opts)
      {:fallback, _reason} = fallback -> fallback
      {:error, _reason} = error -> error
    end
  end

  def open_browser(url) when is_binary(url) do
    with :ok <- validate_verification_url(url), do: launch_browser(url)
  end

  # Only called after web-URL validation; executable is fixed by OS and argv is not a shell.
  # sobelow_skip ["CI.System"]
  defp launch_browser(url) do
    command =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _name} -> {"xdg-open", [url]}
        {:win32, _name} -> {"rundll32.exe", ["url.dll,FileProtocolHandler", url]}
      end

    {executable, args} = command

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp create_authorization(request, base_url, opts) do
    options = [
      method: :post,
      url: endpoint(base_url, "cli/authorizations"),
      json: client_metadata(opts),
      headers: headers(),
      receive_timeout: 10_000,
      retry: false
    ]

    case request.(options) do
      {:ok, %{status: 201, body: body}} -> normalize_authorization(body)
      {:ok, %{status: status}} when status in [404, 405, 501] -> {:fallback, :unsupported}
      {:ok, %{status: 429}} -> {:error, "browser login is rate limited; try again shortly"}
      {:ok, %{status: status, body: body}} -> {:error, http_error(status, body)}
      {:error, _reason} -> {:fallback, :unavailable}
    end
  end

  defp client_metadata(opts) do
    metadata = %{"client" => "mave-cli", "version" => MaveCli.version()}

    case Keyword.get_lazy(opts, :device_name, &MaveCli.DeviceName.get/0) do
      name when is_binary(name) -> Map.put(metadata, "device_name", name)
      _ -> metadata
    end
  end

  defp normalize_authorization(
         %{
           "device_code" => device_code,
           "user_code" => user_code,
           "verification_uri_complete" => verification_uri_complete
         } = body
       )
       when is_binary(device_code) and is_binary(user_code) and
              is_binary(verification_uri_complete) do
    with :ok <- validate_verification_url(verification_uri_complete) do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri_complete: verification_uri_complete,
         expires_in: positive_integer(body["expires_in"], @default_expires_in),
         interval: positive_integer(body["interval"], @default_interval)
       }}
    end
  end

  defp normalize_authorization(_body), do: {:error, "browser login returned an invalid response"}

  defp validate_verification_url(url) do
    with false <- Regex.match?(~r/[\x00-\x20\x7f]/, url),
         {:ok, %URI{host: host, scheme: scheme, userinfo: nil}} <- URI.new(url),
         true <- is_binary(host) and host != "",
         true <-
           scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"]) do
      :ok
    else
      _ ->
        {:error,
         "browser login returned an unsafe verification URL (expected HTTPS or loopback HTTP)"}
    end
  end

  defp authorize_in_browser(authorization, request, base_url, opts) do
    notify = Keyword.get(opts, :notify, &IO.puts/1)
    opener = Keyword.get(opts, :open, &open_browser/1)

    notify.("Open this URL to authorize Mave CLI:")
    notify.(authorization.verification_uri_complete)
    notify.("Authorization code: #{authorization.user_code}")

    case opener.(authorization.verification_uri_complete) do
      :ok ->
        :ok

      {:error, _reason} ->
        notify.("The browser could not be opened automatically; use the URL above.")
    end

    poll(request, base_url, authorization, opts)
  end

  defp poll(request, base_url, authorization, opts) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    monotonic_time = Keyword.get(opts, :monotonic_time, &System.monotonic_time/1)
    deadline = monotonic_time.(:millisecond) + authorization.expires_in * 1_000

    poll_until_complete(
      request,
      base_url,
      authorization.device_code,
      authorization.interval,
      deadline,
      sleep,
      monotonic_time
    )
  end

  defp poll_until_complete(
         request,
         base_url,
         device_code,
         interval,
         deadline,
         sleep,
         monotonic_time
       ) do
    if monotonic_time.(:millisecond) >= deadline do
      {:error, "browser authorization expired"}
    else
      case exchange(request, base_url, device_code, interval) do
        {:ok, token} ->
          {:ok, token}

        {:pending, next_interval} ->
          sleep.(next_interval * 1_000)

          poll_until_complete(
            request,
            base_url,
            device_code,
            next_interval,
            deadline,
            sleep,
            monotonic_time
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp exchange(request, base_url, device_code, interval) do
    options = [
      method: :post,
      url: endpoint(base_url, "cli/authorizations/token"),
      json: %{"device_code" => device_code},
      headers: headers(),
      receive_timeout: 10_000,
      retry: false
    ]

    case request.(options) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{body: %{"error" => "authorization_pending"}}} ->
        {:pending, interval}

      {:ok, %{body: %{"error" => "slow_down"}}} ->
        {:pending, interval + 3}

      {:ok, %{body: %{"error" => "access_denied"}}} ->
        {:error, "browser authorization was cancelled"}

      {:ok, %{body: %{"error" => "expired_token"}}} ->
        {:error, "browser authorization expired"}

      {:ok, %{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, reason} ->
        {:error, "browser authorization failed: #{format_reason(reason)}"}
    end
  end

  defp endpoint(base_url, path), do: String.trim_trailing(base_url, "/") <> "/" <> path

  defp headers do
    [{"accept", "application/json"}, {"user-agent", "mave-cli/#{MaveCli.version()}"}]
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp format_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_reason(reason), do: inspect(reason)

  defp http_error(status, %{"error" => error}) when is_binary(error),
    do: "browser login failed (HTTP #{status}): #{error}"

  defp http_error(status, body) when is_binary(body),
    do: "browser login failed (HTTP #{status}): #{String.slice(body, 0, 200)}"

  defp http_error(status, _body), do: "browser login failed (HTTP #{status})"
end
