# Development

[Back to the README](../README.md)

Development and CI use Elixir 1.20.4 with Erlang/OTP 29.0.6:

```sh
mix local.hex --force
mix deps.get
mix precommit
```

The CLI and its unit tests run independently of a Mave server, database, or
Docker. For integration testing, use a Mave test-space you are authorized to
modify. Configure [custom endpoints](usage.md#custom-endpoints) when testing
against a development server.

`mix precommit` compiles with warnings treated as errors, checks formatting,
runs strict Credo, audits dependencies with `mix hex.audit` and `mix deps.audit`,
runs Sobelow, and executes the tests. `mix lint`, `mix audit`, and `mix security`
(also `mix security.enforce`) run individual groups. These aliases select the
test environment so they do not launch the CLI. Dependency audits require
Hex 2.5.1 or newer and network access to current advisories. Older Hex versions
can miss advisories reported by CI, so the audit stops with an upgrade instruction.

The [CI workflow](../.github/workflows/ci.yml) runs these checks on pushes, pull
requests, and weekly; releases reuse the same gate. Sobelow includes private
functions and fails on any unskipped confidence level. The CLI has no Phoenix
router, so router checks are disabled. Reviewed CLI filesystem operations and
the validated OS browser opener have narrow, documented `sobelow_skip`
annotations. Review those reasons when changing the affected functions; do not
add skips merely to make CI pass. These checks complement manual security
review, rather than proving that the program has no vulnerabilities.

## Run from source

From the repository directory, install dependencies and run without building
a standalone executable:

```sh
mix deps.get
MIX_ENV=test mix run -e 'System.halt(MaveCli.CLI.run(System.argv()))' -- --help
```

To run the checkout from the repository directory, define `mave-local` in your
current shell. The installed `mave` executable continues to run its released
version; local source changes appear only through this helper until rebuilt.

Bash or Zsh:

```sh
mave-local() {
  MIX_ENV=test mix run -e 'System.halt(MaveCli.CLI.run(System.argv()))' -- "$@"
}
mave-local --help
```

Fish:

```fish
function mave-local
    env MIX_ENV=test mix run -e 'System.halt(MaveCli.CLI.run(System.argv()))' -- $argv
end
mave-local --help
```

Use `mave-local` instead of `mave` in the usage examples, for example
`mave-local import vimeo --help`.

Replace `--help` with a CLI command and its options, including
[custom endpoints](usage.md#custom-endpoints) where needed. The test configuration
starts dependencies without automatically invoking the CLI. This command
still makes real requests for API operations; it does not mock the server.
The first run may print compilation output before the command output.

## Standalone binary

Homebrew and direct downloads use the same standalone executable, built with
[Burrito](https://github.com/burrito-elixir/burrito). Users do not need Elixir,
Erlang, or an external OpenSSL installation.

Build natively on the target OS and CPU with Elixir 1.20.4 / OTP 29.0.6,
Python 3.13+, Zig 0.16.0, a C/C++ compiler, Make, Perl, Autoconf, and `xz`.
On macOS, install the Xcode command-line tools. For Linux, use the pinned
Ubuntu 22.04 build image in the [workflow](../.github/workflows/standalone.yml)
to preserve the glibc 2.35 baseline.

```sh
python3 packaging/build_runtime.py --output _build/standalone/runtime --work _build/standalone/work
mix deps.get --only prod --check-locked
MIX_ENV=prod \
BURRITO_TARGET=macos_arm64 \
BURRITO_CUSTOM_ERTS="$PWD/_build/standalone/runtime" \
mix release --overwrite
python3 packaging/smoke_test.py burrito_out/mave_macos_arm64 --version 0.1.0
```

Select the matching native target: `macos_arm64`, `macos_x86_64`, `linux_arm64`,
or `linux_x86_64`. macOS requires version 13 or later; Linux requires glibc
2.35 or later (for example, Ubuntu 22.04). Windows and Alpine/musl packages
are not part of this release pipeline.

The runtime builder verifies the source checksums in
[`runtime.lock.json`](../packaging/runtime.lock.json) and links OpenSSL
statically. The release audits native libraries before wrapping them, rejecting
external package paths, incompatible architectures, and newer OS requirements.
Do not use a local Homebrew Erlang installation as the distributable runtime.
The release hook also applies a guarded Burrito 1.6 compatibility fix so its
Linux wrapper can compile without an unused musl runtime. Revisit this fix
when upgrading Burrito; unexpected upstream changes stop the build.

Build directories are disposable. After changing runtime inputs, use fresh
runtime and work directories. Smoke tests use temporary credentials and a local
HTTP fixture; they test the actual binary, including hidden terminal input,
with system utilities only on `PATH` and a fresh runtime cache.

## Releases

Update the version in `mix.exs` and dependency notices, then run `mix precommit`
and `python3 -m unittest discover -s packaging -p 'test_*.py'`.

Run [Prepare release](../.github/workflows/release.yml) on the reviewed commit
with **Publish the verified release** unchecked to build and test all four
platforms. Download the `release-bundle` artifact for the archives, Homebrew
formula, build information, and checksums.

To publish, push a matching `vVERSION` tag and run the workflow on that tag
with publishing enabled. After the checks pass, it creates the GitHub release.
Copy that release's `mave.rb` to `Formula/mave.rb` in `maveio/homebrew-tap`,
commit and push the formula, then verify `brew install maveio/tap/mave` and
`brew test maveio/tap/mave`.

## Contributing

Keep changes focused and discuss larger features or API changes before
implementing them. Add deterministic regression tests for changed behavior,
update affected documentation, and run the [checks above](#development).
Use your own test-space and synthetic
media for integration tests. Preserve attribution for borrowed material and
keep credentials and customer data out of issues, examples, and commits.

Report vulnerabilities privately as described in [SECURITY.md](../SECURITY.md).
