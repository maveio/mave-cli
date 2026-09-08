# Third-party notices

Third-party code and runtimes retain their own licences and copyright notices.
The project licence, [AGPL-3.0-or-later](LICENSE), applies to Mave-authored code and
documentation; it does not relicense the components below.

## Elixir dependencies

This inventory records the versions in [mix.lock](mix.lock), checked against
the resolved Hex packages' metadata and available licence files. It includes
runtime, build, and test dependencies; it is not a binary SBOM. Update it when
the lockfile changes.

| Package | Version | Declared licence | Role | Source |
| --- | --- | --- | --- | --- |
| bunt | 1.0.0 | MIT | Development dependency through Credo | [Upstream](https://github.com/rrrene/bunt) |
| burrito | 1.6.0 | MIT | Build tool and standalone wrapper | [Upstream](https://github.com/burrito-elixir/burrito) |
| credo | 1.7.19 | MIT | Development static analysis | [Upstream](https://github.com/rrrene/credo) |
| file_system | 1.1.1 | Apache-2.0 | Development dependency through Credo | [Upstream](https://github.com/falood/file_system) |
| finch | 0.23.0 | MIT | HTTP connection pools | [Upstream](https://github.com/sneako/finch) |
| hpax | 1.0.4 | Apache-2.0 | HTTP/2 header compression | [Upstream](https://github.com/elixir-mint/hpax) |
| jason | 1.4.5 | Apache-2.0 | JSON | [Upstream](https://github.com/michalmuskala/jason) |
| mime | 2.0.7 | Apache-2.0 | Media types | [Upstream](https://github.com/elixir-plug/mime) |
| mint | 1.10.0 | Apache-2.0 | HTTP connections | [Upstream](https://github.com/elixir-mint/mint) |
| mix_audit | 2.1.5 | BSD-3-Clause | Development dependency auditing | [Upstream](https://github.com/mirego/mix_audit) |
| nimble_options | 1.1.1 | Apache-2.0 | Option validation | [Upstream](https://github.com/dashbitco/nimble_options) |
| nimble_pool | 1.1.0 | Apache-2.0 | Resource pools | [Upstream](https://github.com/dashbitco/nimble_pool) |
| plug | 1.20.3 | Apache-2.0 | Test HTTP adapter | [Upstream](https://github.com/elixir-plug/plug) |
| plug_crypto | 2.2.0 | Apache-2.0 | Test dependency through Plug | [Upstream](https://github.com/elixir-plug/plug_crypto) |
| req | 0.7.1 | Apache-2.0 | HTTP client | [Upstream](https://github.com/wojtekmach/req) |
| sobelow | 0.15.0 | Apache-2.0 | Development security analysis | [Upstream](https://github.com/sobelow/sobelow) |
| telemetry | 1.4.2 | Apache-2.0 | Runtime instrumentation | [Upstream](https://github.com/beam-telemetry/telemetry) |
| typed_struct | 0.3.0 | MIT | Build dependency through Burrito | [Upstream](https://github.com/ejpcmac/typed_struct) |
| websockex | 0.5.1 | MIT | Upload WebSocket client | [Package source](https://github.com/witchtails/websockex_wt) |
| yamerl | 0.10.0 | BSD-2-Clause | Development dependency through MixAudit | [Upstream](https://github.com/yakaz/yamerl) |
| yaml_elixir | 2.12.2 | MIT | Development dependency through MixAudit | [Upstream](https://github.com/KamilLelonek/yaml-elixir) |

Preserve each distributed dependency's complete licence and attribution files,
including Telemetry's `NOTICE`. NimblePool 1.1.0 records its Apache-2.0 notice
in its `README.md`, rather than a separate licence file: Copyright 2019
Plataformatec; Copyright 2020 Dashbit. Preserve that notice with the complete
Apache-2.0 licence text when distributing it. The table alone does not replace
the required licence files.

## MIT copyright notices

The respective dependency licence files identify these copyright holders:

- Burrito: Copyright (c) 2021 Synopsys, Inc.
- Bunt: Copyright (c) 2015 René Föhring.
- Credo: Copyright (c) 2015-2020 René Föhring.
- Finch: Copyright (c) 2020 Christopher Jon Keathley & Nico Daniel Piderman.
- TypedStruct: Copyright © 2018-2022 Jean-Philippe Cugnet and Contributors.
- WebSockex: Copyright (c) 2017 Justin Baker.
- YamlElixir: Copyright (c) 2025 Kamil Lelonek.

The following MIT text applies to those works, not to the CLI as a whole:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Standalone and Homebrew distributions

Both distributions contain the compiled CLI, Elixir 1.20.4, Erlang/OTP 29.0.6,
and statically linked OpenSSL 3.5.8. The source archives and checksums are pinned
in [the runtime lockfile](packaging/runtime.lock.json). Elixir, current OTP,
and OpenSSL use Apache-2.0 for their main code; separately licensed components
retain their upstream notices.

The runtime builder collects licence, copyright, attribution, and notice
files from the exact OTP and OpenSSL source trees. The package assembler adds
Mave's licence, this inventory, dependency licence and notice files (including
Telemetry's `NOTICE` and NimblePool's README notice), and the
[Elixir 1.20.4 licence](packaging/homebrew/Elixir-LICENSE). These files ship
inside every archive and are installed in Homebrew's package share directory.
The wrapper also includes Zig 0.16.0 standard-library code under its
[MIT licence](packaging/homebrew/Zig-LICENSE) and Burrito's public-domain
[XZ Embedded decoder](packaging/homebrew/XZ-NOTICE).

Each archive also records the source commit, dependency lockfile checksum,
runtime sources, and builder checksum in `build-info.json`. Publish from the
matching source tag, which contains the CLI source and build material. See
[Development](docs/development.md#releases) for the release process.

## Media and marks

The CLI repository does not include video-processing binaries or the Mave
server. The optional local smoke test uses a separately installed FFmpeg; that
tool is not part of the standalone CLI executable.

URLs in examples do not make that media part of the CLI's licence.
Check the original source's terms before redistributing downloaded media.
References to Mave and third-party names do not grant trademark rights for
other products or introduce a separate trademark policy.
