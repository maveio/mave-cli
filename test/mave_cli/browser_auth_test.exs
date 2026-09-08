defmodule MaveCli.BrowserAuthTest do
  use ExUnit.Case, async: true

  alias MaveCli.BrowserAuth

  test "rejects unsafe authorization URLs before opening or polling" do
    for url <- [
          "file:///Applications/Calculator.app",
          "/Applications/Calculator.app",
          "custom-protocol:action",
          "--args",
          "https://user:pass@example.test/login",
          "http://remote.example/login",
          "https://example.test/\nlogin",
          "https:///missing-host"
        ] do
      request = fn _options ->
        {:ok,
         %{
           status: 201,
           body: %{
             "device_code" => "test-device",
             "user_code" => "TEST",
             "verification_uri_complete" => url
           }
         }}
      end

      assert {:error, _} =
               BrowserAuth.login(
                 request: request,
                 open: fn _url -> flunk("unsafe URL reached OS opener") end,
                 notify: fn _message -> flunk("unsafe URL was printed") end
               )

      assert {:error, _} = BrowserAuth.open_browser(url)
    end
  end

  test "allows loopback HTTP authorization for the local development server" do
    request = fn options ->
      if String.ends_with?(options[:url], "/token") do
        {:ok, %{status: 200, body: %{"access_token" => "test-token"}}}
      else
        {:ok,
         %{
           status: 201,
           body: %{
             "device_code" => "test-device",
             "user_code" => "TEST",
             "verification_uri_complete" => "http://localhost:4001/cli/auth/TEST"
           }
         }}
      end
    end

    assert {:ok, "test-token"} =
             BrowserAuth.login(
               base_url: "http://localhost:4001/api/v1/",
               request: request,
               notify: fn _ -> :ok end,
               open: fn url ->
                 assert url == "http://localhost:4001/cli/auth/TEST"
                 :ok
               end
             )
  end

  test "opens the verification URL, polls, and returns the access token" do
    {:ok, request_count} = Agent.start_link(fn -> 0 end)
    parent = self()

    request = fn options ->
      count = Agent.get_and_update(request_count, fn value -> {value, value + 1} end)

      case count do
        0 ->
          assert options[:url] == "https://api.example/v1/cli/authorizations"

          assert options[:json] == %{
                   "client" => "mave-cli",
                   "version" => MaveCli.version(),
                   "device_name" => "Test Mac"
                 }

          {:ok,
           %{
             status: 201,
             body: %{
               "device_code" => "device-secret",
               "user_code" => "ABCDE-FGHIJ",
               "verification_uri_complete" => "https://example.test/cli/auth/ABCDE-FGHIJ",
               "expires_in" => 60,
               "interval" => 4
             }
           }}

        1 ->
          assert options[:url] == "https://api.example/v1/cli/authorizations/token"
          assert options[:json] == %{"device_code" => "device-secret"}
          {:ok, %{status: 400, body: %{"error" => "authorization_pending"}}}

        2 ->
          {:ok, %{status: 200, body: %{"access_token" => "saved-token"}}}
      end
    end

    assert {:ok, "saved-token"} =
             BrowserAuth.login(
               base_url: "https://api.example/v1/",
               device_name: "Test Mac",
               request: request,
               open: fn url ->
                 send(parent, {:opened, url})
                 :ok
               end,
               notify: fn message -> send(parent, {:notice, message}) end,
               sleep: fn milliseconds -> send(parent, {:slept, milliseconds}) end,
               monotonic_time: fn :millisecond -> 0 end
             )

    assert_receive {:opened, "https://example.test/cli/auth/ABCDE-FGHIJ"}
    assert_receive {:notice, "Authorization code: ABCDE-FGHIJ"}
    assert_receive {:slept, 4_000}
  end

  test "omits an unavailable computer name without changing browser authorization" do
    request = fn options ->
      if String.ends_with?(options[:url], "/token") do
        assert options[:json] == %{"device_code" => "test-device"}
        {:ok, %{status: 200, body: %{"access_token" => "test-token"}}}
      else
        assert options[:json] == %{"client" => "mave-cli", "version" => MaveCli.version()}

        {:ok,
         %{
           status: 201,
           body: %{
             "device_code" => "test-device",
             "user_code" => "TEST",
             "verification_uri_complete" => "https://example.test/cli/auth/TEST"
           }
         }}
      end
    end

    assert {:ok, "test-token"} =
             BrowserAuth.login(
               device_name: nil,
               request: request,
               notify: fn _ -> :ok end,
               open: fn _ -> :ok end
             )
  end

  test "falls back when the server has not implemented browser login" do
    request = fn _options -> {:ok, %{status: 404, body: "not found"}} end

    assert {:fallback, :unsupported} =
             BrowserAuth.login(base_url: "https://api.example/v1", request: request)
  end

  test "falls back when the authorization endpoint cannot be reached" do
    request = fn _options -> {:error, :econnrefused} end

    assert {:fallback, :unavailable} =
             BrowserAuth.login(base_url: "https://api.example/v1", request: request)
  end

  test "reports a denied browser authorization without requesting a manual token" do
    {:ok, request_count} = Agent.start_link(fn -> 0 end)

    request = fn _options ->
      case Agent.get_and_update(request_count, fn value -> {value, value + 1} end) do
        0 ->
          {:ok,
           %{
             status: 201,
             body: %{
               "device_code" => "device-secret",
               "user_code" => "ABCDE-FGHIJ",
               "verification_uri_complete" => "https://example.test/cli/auth/ABCDE-FGHIJ"
             }
           }}

        1 ->
          {:ok, %{status: 403, body: %{"error" => "access_denied"}}}
      end
    end

    assert {:error, "browser authorization was cancelled"} =
             BrowserAuth.login(
               base_url: "https://api.example/v1",
               request: request,
               open: fn _url -> :ok end,
               notify: fn _message -> :ok end,
               monotonic_time: fn :millisecond -> 0 end
             )
  end
end
