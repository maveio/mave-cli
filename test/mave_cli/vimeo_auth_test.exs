defmodule MaveCli.VimeoAuthTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias MaveCli.{CLI, Config, PrivateFile, Vimeo}
  alias MaveCli.Vimeo.Auth

  @moduletag :tmp_dir

  setup {Req.Test, :verify_on_exit!}

  setup %{tmp_dir: directory} do
    previous_env =
      Map.new(~w(MAVE_CONFIG_HOME MAVE_TOKEN VIMEO_ACCESS_TOKEN), &{&1, System.get_env(&1)})

    previous_req = Req.default_options()
    System.put_env("MAVE_CONFIG_HOME", directory)
    System.delete_env("MAVE_TOKEN")
    System.delete_env("VIMEO_ACCESS_TOKEN")
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Req.default_options(previous_req)
    end)
  end

  test "first use validates and saves a private token, then reuses it without prompting" do
    expect_validation("vimeo-secret")

    prompt =
      capture_io(:stderr, fn ->
        output =
          capture_io([input: "  vimeo-secret  \n"], fn ->
            assert Vimeo.token() == {:ok, "vimeo-secret"}
          end)

        assert output == ""
      end)

    assert prompt =~ "Vimeo token saved"
    refute prompt =~ "vimeo-secret"
    assert Jason.decode!(File.read!(Auth.path())) == %{"token" => "vimeo-secret"}
    assert Bitwise.band(File.stat!(Auth.path()).mode, 0o777) == 0o600
    refute File.exists?(Config.path())

    assert capture_io(:stderr, fn ->
             assert Vimeo.token() == {:ok, "vimeo-secret"}
           end) == ""
  end

  test "importer login, status and logout work without Mave authentication" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["import", "vimeo", "status"]) == 1
      end)

    assert error =~ "mave import vimeo login"

    expect_validation("first-secret")

    capture_io(:stderr, fn ->
      output =
        capture_io([input: "first-secret\n"], fn ->
          assert CLI.run(["import", "vimeo", "login"]) == 0
        end)

      assert output =~ "Logged in to Vimeo"
      refute output =~ "first-secret"
    end)

    saved = File.read!(Auth.path())
    output = capture_io(fn -> assert CLI.run(["import", "vimeo", "login"]) == 0 end)
    assert output =~ "Already logged in"
    assert output =~ "mave import vimeo logout"
    assert File.read!(Auth.path()) == saved

    output = capture_io(fn -> assert CLI.run(["import", "vimeo", "status"]) == 0 end)
    assert output =~ Auth.path()
    refute output =~ "first-secret"

    for _ <- 1..2 do
      output = capture_io(fn -> assert CLI.run(["import", "vimeo", "logout"]) == 0 end)
      assert output =~ "Saved Vimeo token removed"
      refute File.exists?(Auth.path())
    end

    expect_validation("second-secret")

    capture_io(:stderr, fn ->
      capture_io([input: "second-secret\n"], fn ->
        assert CLI.run(["import", "vimeo", "login"]) == 0
      end)
    end)

    assert Vimeo.token() == {:ok, "second-secret"}
    refute File.exists?(Config.path())
  end

  test "Mave and Vimeo logout preserve each other's login and import progress" do
    assert :ok = Config.save_token("mave-secret")
    save_token("vimeo-secret")
    state_path = Path.join([Path.dirname(Config.path()), "imports", "state.json"])
    assert :ok = PrivateFile.write_atomic(state_path, "saved-import-progress")

    capture_io(fn -> assert CLI.run(["logout"]) == 0 end)
    assert Vimeo.token() == {:ok, "vimeo-secret"}
    assert File.read!(state_path) == "saved-import-progress"

    assert :ok = Config.save_token("mave-secret")
    saved_mave = File.read!(Config.path())
    capture_io(fn -> assert CLI.run(["import", "vimeo", "logout"]) == 0 end)
    assert Config.token() == {:ok, "mave-secret"}
    assert File.read!(Config.path()) == saved_mave
    assert File.read!(state_path) == "saved-import-progress"
    refute File.exists?(Auth.path())
  end

  test "environment tokens override saved credentials without being persisted" do
    System.put_env("VIMEO_ACCESS_TOKEN", "  environment-secret  ")
    assert Vimeo.token() == {:ok, "environment-secret"}
    assert {:ok, message} = Auth.login()
    assert message =~ "VIMEO_ACCESS_TOKEN"
    refute message =~ "environment-secret"
    refute File.exists?(Auth.path())

    save_token("saved-secret")
    saved = File.read!(Auth.path())
    assert Vimeo.token() == {:ok, "environment-secret"}
    assert {:ok, "Logged in to Vimeo via VIMEO_ACCESS_TOKEN."} = Auth.status()
    assert File.read!(Auth.path()) == saved

    System.put_env("VIMEO_ACCESS_TOKEN", "   ")
    assert Vimeo.token() == {:ok, "saved-secret"}
    System.put_env("VIMEO_ACCESS_TOKEN", "environment-secret")

    output = capture_io(fn -> assert CLI.run(["import", "vimeo", "logout"]) == 0 end)
    assert output =~ "VIMEO_ACCESS_TOKEN is still set"
    refute output =~ "environment-secret"
    refute File.exists?(Auth.path())
    assert Vimeo.token() == {:ok, "environment-secret"}
  end

  test "rejected tokens are not saved or exposed" do
    for status <- [401, 403] do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(Plug.Conn.put_status(conn, status), %{"error" => "vimeo-secret"})
      end)

      error =
        capture_io(:stderr, fn ->
          output =
            capture_io([input: "vimeo-secret\n"], fn ->
              assert CLI.run(["import", "vimeo", "login"]) == 1
            end)

          assert output == ""
        end)

      refute error =~ "vimeo-secret"
      refute error =~ "Vimeo token saved"
      refute File.exists?(Auth.path())
    end
  end

  test "a rate-limited login retries the same entered token and saves it after validation" do
    Req.default_options(plug: {Req.Test, __MODULE__}, retry_delay: fn _ -> 0 end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vimeo-secret"]
      Plug.Conn.send_resp(conn, 429, "private-body")
    end)

    expect_validation("vimeo-secret")

    prompt =
      capture_io(:stderr, fn ->
        output =
          capture_io([input: "vimeo-secret\n"], fn ->
            assert CLI.run(["import", "vimeo", "login"]) == 0
          end)

        assert output =~ "Logged in to Vimeo"
        refute output =~ "vimeo-secret"
      end)

    assert prompt =~ "waiting 60s"
    assert prompt =~ "Vimeo token saved"
    assert length(Regex.scan(~r/^Vimeo access token: /m, prompt)) == 1
    assert Vimeo.token() == {:ok, "vimeo-secret"}
    refute prompt =~ "vimeo-secret"
    refute prompt =~ "private-body"
  end

  test "a long cooldown reports when to retry login without saving an unvalidated token" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "900")
      |> Plug.Conn.send_resp(429, "private-body")
    end)

    error =
      capture_io(:stderr, fn ->
        output =
          capture_io([input: "vimeo-secret\n"], fn ->
            assert CLI.run(["import", "vimeo", "login"]) == 1
          end)

        assert output == ""
      end)

    assert error =~ "in about 900 seconds"
    assert error =~ "token has not been saved"
    refute error =~ "vimeo-secret"
    refute error =~ "private-body"
    refute File.exists?(Auth.path())
  end

  test "blank input and EOF do not save a token or contact Vimeo" do
    for {input, message} <- [
          {"  \n", "Vimeo token must not be empty"},
          {"", "could not read Vimeo token"}
        ] do
      error =
        capture_io(:stderr, fn ->
          capture_io([input: input], fn ->
            assert CLI.run(["import", "vimeo", "login"]) == 1
          end)
        end)

      assert error =~ message
      refute File.exists?(Auth.path())
    end
  end

  test "invalid saved credentials can be removed without exposing their contents" do
    assert :ok = PrivateFile.write_atomic(Auth.path(), "invalid-private-content")
    assert {:error, message} = Auth.token()
    assert message =~ "mave import vimeo logout"
    refute message =~ "invalid-private-content"
    assert {:ok, _} = Auth.logout()
    assert {:error, message} = Auth.status()
    assert message =~ "no Vimeo token found"
  end

  test "a failed save does not report a successful login" do
    Req.Test.expect(__MODULE__, fn conn ->
      File.mkdir_p!(Auth.path())
      Req.Test.json(conn, %{"uri" => "/users/42"})
    end)

    error =
      capture_io(:stderr, fn ->
        output =
          capture_io([input: "vimeo-secret\n"], fn ->
            assert CLI.run(["import", "vimeo", "login"]) == 1
          end)

        assert output == ""
      end)

    assert error =~ "could not save the Vimeo token"
    refute error =~ "vimeo-secret"
    refute error =~ "Vimeo token saved"
    assert File.ls!(Auth.path()) == []
  end

  test "importer help lists credential commands and unknown subcommands fail before login" do
    output = capture_io(fn -> assert CLI.run(["import", "vimeo", "--help"]) == 0 end)

    for action <- ["login", "status", "logout"] do
      assert output =~ "mave import vimeo #{action}"
    end

    for args <- [["unknown"], ["login", "unexpected-secret"]] do
      error =
        capture_io(:stderr, fn ->
          assert CLI.run(["import", "vimeo"] ++ args) == 1
        end)

      assert error =~ "usage: mave import vimeo"
      refute error =~ "unexpected-secret"
    end

    refute File.exists?(Auth.path())
  end

  defp expect_validation(token) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api.vimeo.com"
      assert conn.method == "GET"
      assert conn.request_path == "/me"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> token]
      Req.Test.json(conn, %{"uri" => "/users/42"})
    end)
  end

  defp save_token(token),
    do: assert(:ok == PrivateFile.write_atomic(Auth.path(), Jason.encode!(%{"token" => token})))
end
