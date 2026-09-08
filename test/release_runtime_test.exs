defmodule MaveCli.ReleaseRuntimeTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "replaces only native files from OTP apps and handles the glibc wrapper", %{tmp_dir: root} do
    runtime = Path.join(root, "runtime")
    release = Path.join(root, "release")
    wrapper = Path.join(root, "burrito/src/wrapper.zig")
    old_nif = Path.join(release, "lib/crypto-5.9.3/priv/lib/crypto_callback.so")
    other_nif = Path.join(release, "lib/custom_app-1.0/priv/lib/custom.so")

    File.mkdir_p!(Path.join(runtime, "otp/lib/crypto-5.9.3"))

    for file <- [old_nif, other_nif, wrapper] do
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "fixture")
    end

    File.write!(wrapper, "if (!std.mem.eql(u8, build_options.MUSL_RUNTIME_PATH, \"\")) {}")

    context = %{
      target: %{os: :linux, erts_source: {:local_unpacked, path: runtime}},
      self_dir: Path.join(root, "burrito"),
      work_dir: release
    }

    assert MaveCli.ReleaseRuntime.execute(context) == context
    refute File.exists?(old_nif)
    assert File.read!(other_nif) == "fixture"
    assert File.read!(wrapper) =~ "if (comptime !std.mem.eql"
    assert MaveCli.ReleaseRuntime.execute(context) == context
  end

  test "stops when an upstream wrapper change needs review", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/wrapper.zig"), "changed upstream")

    context = %{
      target: %{os: :linux, erts_source: {:local_unpacked, path: root}},
      self_dir: root,
      work_dir: root
    }

    assert_raise Mix.Error, ~r/Linux wrapper changed/, fn ->
      MaveCli.ReleaseRuntime.execute(context)
    end
  end
end
