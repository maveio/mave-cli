defmodule MaveCli.CLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.fetch_env(:req, :default_options)
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      case previous do
        {:ok, options} -> Req.default_options(options)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)
  end

  for resource <- ["videos", "collections"],
      {action, flags, expected} <- [
        {"rename", ["--name", "Renamed"], %{"name" => "Renamed"}},
        {"move", ["--collection", "parent"], %{"collection" => "parent"}},
        {"move to root", ["--root"],
         %{"collection" => if(resource == "videos", do: nil, else: "")}}
      ] do
    test "#{resource} update can #{action}" do
      resource = unquote(resource)
      expected = unquote(Macro.escape(expected))

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/v1/#{resource}/item"
        assert Jason.decode!(Req.Test.raw_body(conn)) == expected
        Req.Test.json(conn, Map.put(expected, "id", "item"))
      end)

      output =
        capture_io(fn ->
          assert MaveCli.CLI.run(
                   [
                     resource,
                     "update",
                     "item",
                     "--base-url",
                     "http://local.test/api/v1/",
                     "--token",
                     "test-token"
                   ] ++
                     unquote(flags)
                 ) == 0
        end)

      assert Jason.decode!(output) == Map.put(expected, "id", "item")
    end
  end

  test "help is available without authentication" do
    output = capture_io(fn -> assert MaveCli.CLI.run(["--help"]) == 0 end)
    assert output =~ "mave videos list"
    assert output =~ "mave spaces create"
    assert output =~ "mave webhooks verify"
    assert output =~ "mave sources manifest"
  end

  test "generates an upload token for any documented upload subject" do
    output =
      capture_io(fn ->
        assert MaveCli.CLI.run([
                 "upload-token",
                 "collection-123",
                 "--expires-in",
                 "60",
                 "--token",
                 "secret"
               ]) == 0
      end)

    result = Jason.decode!(output)
    assert result["subject"] == "collection-123"
    assert is_binary(result["token"])
    assert result["expires_at"] > System.system_time(:second)
  end

  test "verifies webhook payloads without API authentication" do
    payload = ~s({"type":"video.ready"})
    timestamp = "100"
    secret = "secret"

    signature =
      :crypto.mac(:hmac, :sha256, timestamp <> "." <> secret, payload)
      |> Base.encode16(case: :lower)

    output =
      capture_io(payload, fn ->
        assert MaveCli.CLI.run([
                 "webhooks",
                 "verify",
                 "-",
                 "--signature",
                 "t=#{timestamp},v1=#{signature}",
                 "--secret",
                 secret
               ]) == 0
      end)

    assert Jason.decode!(output) == %{"timestamp" => timestamp, "valid" => true}
  end

  test "prints the version" do
    output = capture_io(fn -> assert MaveCli.CLI.run(["--version"]) == 0 end)
    assert String.trim(output) == MaveCli.version()
  end

  describe "manual login" do
    @describetag :tmp_dir

    setup %{tmp_dir: directory} do
      previous_home = System.get_env("MAVE_CONFIG_HOME")
      previous_token = System.get_env("MAVE_TOKEN")
      System.put_env("MAVE_CONFIG_HOME", directory)
      System.delete_env("MAVE_TOKEN")

      on_exit(fn ->
        restore_env("MAVE_CONFIG_HOME", previous_home)
        restore_env("MAVE_TOKEN", previous_token)
      end)
    end

    test "reads a piped token without printing it and binds it to the chosen server" do
      input = "  synthetic-login-token  \n"

      prompt =
        capture_io(:stderr, fn ->
          output =
            capture_io([input: input], fn ->
              assert MaveCli.CLI.run([
                       "auth",
                       "login",
                       "--no-browser",
                       "--base-url",
                       "http://local.test/api/v1/"
                     ]) == 0
            end)

          assert output =~ "Mave token saved"
          refute output =~ "synthetic-login-token"
        end)

      assert prompt == "Mave API token: "

      assert {:ok, "synthetic-login-token"} =
               MaveCli.Config.token(nil, base_url: "http://local.test/api/v1/")
    end

    test "rejects blank input and EOF without saving credentials" do
      for {input, message} <- [
            {"  \n", "token must not be empty"},
            {"", "could not read token"}
          ] do
        error =
          capture_io(:stderr, fn ->
            capture_io([input: input], fn ->
              assert MaveCli.CLI.run(["auth", "login", "--no-browser"]) == 1
            end)
          end)

        assert error =~ message
        refute File.exists?(MaveCli.Config.path())
      end
    end
  end

  test "routes source commands to the selected local CDN" do
    output =
      capture_io(fn ->
        assert MaveCli.CLI.run([
                 "sources",
                 "url",
                 "ubg50Cq5Ilpnar1",
                 "manifest.json",
                 "--cdn-base-url",
                 "http://localhost:9010/space-{space}"
               ]) == 0
      end)

    assert Jason.decode!(output) == %{
             "url" => "http://localhost:9010/space-ubg50/Cq5Ilpnar1/manifest.json"
           }
  end

  test "API commands without a token fail before making a request" do
    previous_token = System.get_env("MAVE_TOKEN")
    previous_home = System.get_env("MAVE_CONFIG_HOME")
    System.delete_env("MAVE_TOKEN")
    System.put_env("MAVE_CONFIG_HOME", Path.join(System.tmp_dir!(), "mave-missing-token-test"))

    on_exit(fn ->
      restore_env("MAVE_TOKEN", previous_token)
      restore_env("MAVE_CONFIG_HOME", previous_home)
    end)

    error = capture_io(:stderr, fn -> assert MaveCli.CLI.run(["videos", "list"]) == 1 end)
    assert error =~ "no token found"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
