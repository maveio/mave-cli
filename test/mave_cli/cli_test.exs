defmodule MaveCli.CLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias MaveCli.Vimeo.Auth, as: VimeoAuth

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
    assert output =~ "mave import vimeo"
    assert output =~ "mave login"
    assert output =~ "mave logout"
  end

  test "import discovery and help do not require credentials or contact either API" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("help must not make API requests") end)

    for args <- [["import"], ["import", "--help"], ["import", "vimeo", "--help"]] do
      prompt =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> assert MaveCli.CLI.run(args) == 0 end)
          assert output =~ "mave import vimeo"
          assert output =~ "folder structure"
          refute output =~ "mave videos delete"
        end)

      assert prompt == ""
    end

    output = capture_io(fn -> assert MaveCli.CLI.run(["import", "vimeo", "--help"]) == 0 end)
    assert output =~ "VIMEO_ACCESS_TOKEN"
    assert output =~ "--folder ID"
    assert output =~ "--resume"
  end

  test "unknown importers explain how to find supported providers before authentication" do
    error = capture_io(:stderr, fn -> assert MaveCli.CLI.run(["import", "unknown"]) == 1 end)
    assert error =~ "unknown importer"
    assert error =~ "use `mave import`"
  end

  describe "Vimeo imports" do
    @describetag :tmp_dir

    setup %{tmp_dir: directory} do
      previous = System.get_env("VIMEO_ACCESS_TOKEN")
      previous_home = System.get_env("MAVE_CONFIG_HOME")
      System.put_env("VIMEO_ACCESS_TOKEN", "synthetic-vimeo-token")
      System.put_env("MAVE_CONFIG_HOME", directory)

      on_exit(fn ->
        restore_env("VIMEO_ACCESS_TOKEN", previous)
        restore_env("MAVE_CONFIG_HOME", previous_home)
      end)

      Req.Test.stub(__MODULE__, fn conn ->
        body =
          case {conn.host, conn.request_path} do
            {"api.vimeo.com", "/me"} ->
              %{"uri" => "/users/42"}

            {"api.vimeo.com", "/me/projects"} ->
              %{"data" => [], "paging" => %{"next" => nil}}

            {"api.vimeo.com", "/me/videos"} ->
              %{
                "data" => [%{"uri" => "/videos/101", "name" => "Example title"}],
                "paging" => %{"next" => nil}
              }

            {"api.vimeo.com", "/videos/101"} ->
              %{"files" => []}

            {"local.test", "/v1/videos"} ->
              %{"space_id" => "space-1", "data" => []}
          end

        assert conn.method == "GET"
        Req.Test.json(conn, body)
      end)
    end

    test "guides users without a Vimeo token and keeps token input out of output" do
      for token <- [nil, "   "] do
        restore_env("VIMEO_ACCESS_TOKEN", token)
        assert {:ok, _message} = VimeoAuth.logout()

        prompt =
          capture_io(:stderr, fn ->
            output =
              capture_io([input: "  synthetic-pasted-token\n"], fn ->
                assert MaveCli.Vimeo.token() == {:ok, "synthetic-pasted-token"}
              end)

            assert output == ""
          end)

        assert prompt =~ "https://developer.vimeo.com/apps"
        assert prompt =~ "Authenticated (you)"
        assert prompt =~ "Public, Private and Video Files"
        assert prompt =~ "Vimeo access token: "
        refute prompt =~ "synthetic-pasted-token"
      end
    end

    test "an environment token bypasses the setup guidance and prompt" do
      prompt =
        capture_io(:stderr, fn ->
          output =
            capture_io(fn ->
              assert MaveCli.Vimeo.token() == {:ok, "synthetic-vimeo-token"}
            end)

          assert output == ""
        end)

      assert prompt == ""
      refute File.exists?(VimeoAuth.path())
    end

    test "imports reuse the token saved by the first prompt", %{tmp_dir: directory} do
      System.delete_env("VIMEO_ACCESS_TOKEN")

      args = [
        "import",
        "vimeo",
        "--dry-run",
        "--no-progress",
        "--base-url",
        "http://local.test/v1/",
        "--token",
        "mave-secret",
        "--state-file",
        Path.join(directory, "import.json")
      ]

      for input <- ["pasted-vimeo-token\n", ""] do
        prompt =
          capture_io(:stderr, fn ->
            output =
              capture_io([input: input], fn ->
                assert MaveCli.CLI.run(args) == 0
              end)

            assert Jason.decode!(output)["videos"] == 1
            refute output =~ "pasted-vimeo-token"
          end)

        if input == "", do: assert(prompt == ""), else: assert(prompt =~ "Vimeo token saved")
      end

      refute File.exists?(Path.join(directory, "import.json"))
    end

    test "dry-run accepts importer flags and prints a readable preview", %{tmp_dir: directory} do
      path = Path.join(directory, "state.json")

      output =
        capture_io(fn ->
          assert MaveCli.CLI.run([
                   "import",
                   "vimeo",
                   "--dry-run",
                   "--collection",
                   "target",
                   "--format",
                   "table",
                   "--state-file",
                   path,
                   "--no-progress",
                   "--base-url",
                   "http://local.test/v1/",
                   "--token",
                   "mave-token"
                 ]) == 0
        end)

      assert output =~ "Example title"
      assert output =~ "planned"
      refute File.exists?(path)
    end

    test "unavailable videos produce JSON and a nonzero exit status", %{tmp_dir: directory} do
      output =
        capture_io(fn ->
          assert MaveCli.CLI.run([
                   "import",
                   "vimeo",
                   "--state-file",
                   Path.join(directory, "state.json"),
                   "--no-progress",
                   "--base-url",
                   "http://local.test/v1/",
                   "--token",
                   "mave-token"
                 ]) == 1
        end)

      assert %{"failed" => 1, "data" => [%{"name" => "Example title", "status" => "failed"}]} =
               Jason.decode!(output)

      refute output =~ "synthetic-vimeo-token"
    end

    test "rejects invalid folder IDs before accessing an account" do
      error =
        capture_io(:stderr, fn ->
          assert MaveCli.CLI.run(["import", "vimeo", "--folder", "../other", "--token", "test"]) ==
                   1
        end)

      assert error =~ "--folder must be a numeric Vimeo folder ID"
    end
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

  describe "login" do
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

    test "repeated login keeps existing credentials and never starts browser authorization" do
      assert :ok = MaveCli.Config.save_token("existing-secret", base_url: "http://local.test/v1/")
      saved = File.read!(MaveCli.Config.path())

      Req.Test.stub(__MODULE__, fn _conn ->
        flunk("an existing login must not make HTTP requests")
      end)

      for command <- [["auth", "login"], ["login"]],
          arguments <- [
            [],
            ["--no-browser"],
            ["replacement-secret"],
            ["--token", "replacement-secret"]
          ] do
        prompt =
          capture_io(:stderr, fn ->
            output =
              capture_io(fn ->
                assert MaveCli.CLI.run(
                         command ++ ["--base-url", "http://local.test/v1"] ++ arguments
                       ) == 0
              end)

            assert output =~ "Already logged in"
            assert output =~ "mave logout"
            refute output =~ "existing-secret"
            refute output =~ "replacement-secret"
          end)

        assert prompt == ""
        assert File.read!(MaveCli.Config.path()) == saved
      end
    end

    test "an environment token prevents creating a new login without persisting the token" do
      System.put_env("MAVE_TOKEN", "environment-secret")

      Req.Test.stub(__MODULE__, fn _conn ->
        flunk("environment authentication must not start login")
      end)

      output = capture_io(fn -> assert MaveCli.CLI.run(["auth", "login"]) == 0 end)
      assert output =~ "Already authenticated via MAVE_TOKEN"
      assert output =~ "Unset MAVE_TOKEN"
      refute output =~ "environment-secret"
      refute File.exists?(MaveCli.Config.path())
    end

    test "logout permits a new browser login" do
      for command <- [["auth", "logout"], ["logout"]] do
        assert :ok =
                 MaveCli.Config.save_token("existing-secret", base_url: "http://local.test/v1/")

        capture_io(fn -> assert MaveCli.CLI.run(command) == 0 end)
        refute File.exists?(MaveCli.Config.path())
      end

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/cli/authorizations"
        Plug.Conn.send_resp(conn, 501, "")
      end)

      capture_io(:stderr, fn ->
        capture_io([input: "replacement-secret\n"], fn ->
          assert MaveCli.CLI.run(["auth", "login", "--base-url", "http://local.test/v1/"]) == 0
        end)
      end)

      assert {:ok, "replacement-secret"} =
               MaveCli.Config.token(nil, base_url: "http://local.test/v1/")
    end

    test "credentials saved for a different server do not block login" do
      assert :ok = MaveCli.Config.save_token("first-secret", base_url: "https://first.test/v1/")

      output =
        capture_io(fn ->
          assert MaveCli.CLI.run([
                   "auth",
                   "login",
                   "second-secret",
                   "--base-url",
                   "https://second.test/v1/"
                 ]) == 0
        end)

      assert output =~ "Mave token saved"

      assert {:ok, "second-secret"} =
               MaveCli.Config.token(nil, base_url: "https://second.test/v1/")
    end

    test "legacy unbound credentials can be replaced with a server-bound login" do
      File.mkdir_p!(Path.dirname(MaveCli.Config.path()))
      File.write!(MaveCli.Config.path(), Jason.encode!(%{"token" => "unbound-secret"}))

      capture_io(fn ->
        assert MaveCli.CLI.run([
                 "auth",
                 "login",
                 "bound-secret",
                 "--base-url",
                 "https://local.test/v1/"
               ]) == 0
      end)

      assert {:ok, "bound-secret"} = MaveCli.Config.token(nil, base_url: "https://local.test/v1/")
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
