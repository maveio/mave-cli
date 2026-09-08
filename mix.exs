defmodule MaveCli.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mave_cli,
      version: @version,
      elixir: "~> 1.20.4",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl],
      mod: {MaveCli.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        audit: :test,
        lint: :test,
        security: :test,
        "security.enforce": :test,
        precommit: :test
      ]
    ]
  end

  defp aliases do
    [
      audit: [&ensure_current_hex/1, "hex.audit", "deps.audit"],
      lint: ["format --check-formatted", "credo --strict"],
      security: ["audit", "sobelow --private --no-router --skip --exit low"],
      "security.enforce": ["security"],
      precommit: ["security", "compile --warnings-as-errors", "lint", "test"]
    ]
  end

  defp ensure_current_hex(_) do
    unless Code.ensure_loaded?(Hex) and Version.match?(Hex.version(), ">= 2.5.1") do
      Mix.raise("Security audits require Hex 2.5.1 or newer. Run: mix local.hex --force")
    end
  end

  defp deps do
    [
      {:burrito, "~> 1.5", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.16", only: :test},
      {:req, "~> 0.5"},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false},
      {:websockex, "~> 0.5.1"}
    ]
  end

  defp releases do
    [
      mave: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          extra_steps: [patch: [pre: [MaveCli.ReleaseRuntime], post: [MaveCli.ReleaseAudit]]],
          targets: [
            macos_arm64: target(:darwin, :aarch64),
            macos_x86_64: target(:darwin, :x86_64),
            linux_arm64: target(:linux, :aarch64),
            linux_x86_64: target(:linux, :x86_64)
          ]
        ]
      ]
    ]
  end

  defp target(os, cpu) do
    [os: os, cpu: cpu]
    |> maybe_add_custom_erts(System.get_env("BURRITO_CUSTOM_ERTS"))
  end

  defp maybe_add_custom_erts(target, nil), do: target
  defp maybe_add_custom_erts(target, path), do: Keyword.put(target, :custom_erts, path)
end

defmodule MaveCli.ReleaseRuntime do
  @moduledoc false

  def execute(context) do
    case context.target.erts_source do
      {:local_unpacked, path: root} ->
        prepare_linux_wrapper(context)

        # Burrito replaces matching files but otherwise retains host-only NIFs.
        # Clear native files only for OTP apps supplied by our replacement runtime.
        for app <- Path.wildcard(Path.join(root, "otp/lib/*")),
            file <-
              Path.wildcard(
                Path.join([
                  context.work_dir,
                  "lib",
                  Path.basename(app),
                  "priv/**/*.{so,dll,dylib}"
                ])
              ) do
          File.rm!(file)
        end

      _ ->
        :ok
    end

    context
  end

  defp prepare_linux_wrapper(%{target: %{os: :linux}, self_dir: directory}) do
    # Burrito 1.6 still resolves @embedFile for a disabled musl runtime.
    # Make the guard compile-time so custom glibc runtimes need no musl file.
    file = Path.join(directory, "src/wrapper.zig")
    original = "if (!std.mem.eql(u8, build_options.MUSL_RUNTIME_PATH, \"\")) {"
    replacement = "if (comptime !std.mem.eql(u8, build_options.MUSL_RUNTIME_PATH, \"\")) {"
    source = File.read!(file)

    cond do
      String.contains?(source, original) ->
        File.write!(file, String.replace(source, original, replacement))

      String.contains?(source, replacement) ->
        :ok

      true ->
        Mix.raise("Burrito's Linux wrapper changed; review the custom-runtime compatibility fix")
    end
  end

  defp prepare_linux_wrapper(_context), do: :ok
end

defmodule MaveCli.ReleaseAudit do
  @moduledoc false

  def execute(context) do
    {_, status} =
      System.cmd(
        "python3",
        [
          "packaging/verify_native.py",
          context.work_dir,
          "--target",
          to_string(context.target.alias)
        ],
        into: IO.stream()
      )

    if status != 0,
      do: Mix.raise("The bundled runtime is not portable; see the native dependency audit")

    context
  end
end
