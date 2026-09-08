<a href="https://mave.io">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mave-logo-white.svg">
    <img src="docs/images/mave-logo.svg" alt="Mave" width="183">
  </picture>
</a>

# Mave CLI

A command-line client for [Mave](https://www.mave.io/). Manage videos and
collections, upload files, and use JSON output in your scripts.

## Installation

Install with Homebrew:

```sh
brew install maveio/tap/mave
```

The package includes its runtime; you do not need to install Elixir or Erlang.
Supports macOS 13+ and glibc-based Linux (2.35+), on ARM64 and x86-64.

For running or building from source, see the [development guide](docs/development.md).

## Get started

```sh
mave auth login
mave videos list --format table
mave videos upload ./video.mp4 --wait
mave collections create --name "Product videos"
```

Login opens your browser and saves a token locally, bound to the selected
server. Commands return JSON by default; use `--format table` for readable
output and `mave --help` for available commands.

## Documentation

- [Usage and command reference](docs/usage.md) — uploads, tokens, webhooks, and source files.
- [Custom endpoints](docs/usage.md#custom-endpoints) — configure API, upload, and CDN endpoints.
- [Development](docs/development.md) — setup, checks, and standalone builds.

## Contributing

Run `mix precommit` to check tests, formatting, Credo, Sobelow, and dependencies.
See the [contribution guide](docs/development.md#contributing) for details.
Report vulnerabilities privately through [SECURITY.md](SECURITY.md).

## License

[AGPL-3.0-or-later](LICENSE). Copyright (c) mave.io B.V.
See [third-party notices](THIRD_PARTY_NOTICES.md) for dependency licences.
