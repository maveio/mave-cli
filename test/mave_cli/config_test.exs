defmodule MaveCli.ConfigTest do
  use ExUnit.Case, async: false

  alias MaveCli.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    previous_home = System.get_env("MAVE_CONFIG_HOME")
    previous_token = System.get_env("MAVE_TOKEN")
    System.put_env("MAVE_CONFIG_HOME", directory)
    System.delete_env("MAVE_TOKEN")

    on_exit(fn ->
      restore_env("MAVE_CONFIG_HOME", previous_home)
      restore_env("MAVE_TOKEN", previous_token)
    end)

    :ok
  end

  test "token precedence is flag, environment, config" do
    assert Config.resolve_token("flag", "env", "stored") == "flag"
    assert Config.resolve_token(nil, "env", "stored") == "env"
    assert Config.resolve_token(nil, nil, "stored") == "stored"
    assert Config.resolve_token("", "", nil) == nil
  end

  test "stored tokens are sent only to their bound API base URL" do
    assert :ok = Config.save_token("test-token", base_url: "https://first.example/v1/")
    assert {:ok, "test-token"} = Config.token(nil, base_url: "https://first.example/v1")

    for url <- [
          "https://second.example/v1/",
          "http://first.example/v1/",
          "https://first.example/other/"
        ] do
      assert {:error, _} = Config.token(nil, base_url: url)
      assert Config.source(nil, base_url: url) == :different_server
    end

    assert {:ok, "explicit"} = Config.token("explicit", base_url: "https://second.example/v1")
    System.put_env("MAVE_TOKEN", "environment")
    assert {:ok, "environment"} = Config.token(nil, base_url: "https://second.example/v1")
  end

  test "legacy credentials require reauthentication instead of guessing their server" do
    File.mkdir_p!(Path.dirname(Config.path()))
    File.write!(Config.path(), Jason.encode!(%{"token" => "legacy-test-token"}))

    assert {:error, _} = Config.token()
    assert {:error, _} = Config.token(nil, base_url: "https://other.example/v1")
    assert Config.source() == :unbound
  end

  test "saving replaces a symlink without modifying its target", %{tmp_dir: directory} do
    if match?({:unix, _}, :os.type()) do
      unrelated = Path.join(directory, "unrelated.txt")
      File.write!(unrelated, "keep")
      File.mkdir_p!(Path.dirname(Config.path()))
      File.ln_s!(unrelated, Config.path())

      assert :ok = Config.save_token("synthetic-token")
      assert File.read!(unrelated) == "keep"
      assert File.lstat!(Config.path()).type == :regular
      assert Bitwise.band(File.stat!(Config.path()).mode, 0o777) == 0o600
      assert Path.wildcard(Path.join(Path.dirname(Config.path()), "mave-cli-*")) == []
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
