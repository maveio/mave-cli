# Security

## Reporting a vulnerability

Report suspected vulnerabilities privately to [cert@mave.io](mailto:cert@mave.io).
Follow [Mave's responsible-disclosure policy](https://www.mave.io/docs/responsible-disclosure/)
for the disclosure process and the conditions for testing Mave-operated systems.
Do not post credentials, customer data, or exploit details in public issues or
pull requests.

Include the affected CLI version or commit, operating system, target server,
relevant configuration with secrets removed, required access, reproduction
steps, expected and actual behaviour, and the potential impact. Prefer a
minimal reproduction using your own installation and synthetic data.

This file does not authorize testing other people's installations or extend
response-time, reward, or support commitments to third-party deployments.

## Scope and trust boundaries

This policy covers the CLI in this repository: browser and token login, local
configuration, API requests, upload-token generation, WebSocket and TUS uploads,
remote downloads, CDN source access, webhook verification, and the build and
release configuration for standalone executables.

The CLI runs with the filesystem and network permissions of its local user.
That user chooses arguments, environment variables, configuration, endpoints,
source files, and download destinations. Responses from API servers, browser
authorization endpoints, upload servers, remote sources, and CDNs can contain
untrusted data, including URLs, filenames, headers, and error messages.

API tokens, upload credentials, webhook secrets, local files, and downloaded
media cross different boundaries. Choosing a server or source URL must not
implicitly authorize disclosure of unrelated credentials or local files.
The Mave server enforces space isolation and API-key permissions; the CLI must
preserve those contracts and report server failures accurately.

CLI vulnerabilities remain in scope whether the connected server is
self-hosted or Mave-operated. Server implementations are maintained in separate
repositories; include the affected server details when a report spans CLI and
server behavior.

## Security expectations

- Login tokens and upload credentials must be used only for their intended
  authorization flow and destination. Remote URLs and redirects must not cause
  credential disclosure to an unrelated host.
- Secrets must not leak through progress output, diagnostics, or downloaded
  filenames. Commands that intentionally return credentials, such as
  `upload-token` and `spaces create --return-key`, must clearly identify their
  output as sensitive.
- Local credential storage must respect the selected configuration directory
  and appropriate file permissions. Temporary downloads and destination paths
  must not allow unintended file disclosure, traversal, or overwriting.
- TLS verification must not be silently disabled. Support for explicitly
  configured local HTTP/WS endpoints must not downgrade a remote connection.
- Remote payloads must remain data: they must not become shell commands or
  executable configuration. Parsing and transfer behavior must account for
  malformed input and realistic resource exhaustion.
- Upload-token signing and webhook verification must preserve the documented
  cryptographic contracts. Invalid signatures and failed transfers must not be
  reported as successful.
- Release artifacts and their build inputs must preserve the intended code,
  dependency provenance, and notices, without including local credentials or
  private test data.

Reports should explain realistic reachability, prerequisites, and impact.
Passing tests or a scanner's configured exclusions do not establish that a
control is safe. Disclosure-program eligibility is not a blanket exclusion from
reviewing a security defect in the CLI.

## Current behavior

The stored API token is bound to the API base URL selected at login; a mismatch
or an older unbound config requires a new login. Explicit `--token` and
`MAVE_TOKEN` credentials apply to the selected command endpoint. Select a
separate `MAVE_CONFIG_HOME` for each environment. `auth status` reports the
presence, source, and local binding of a token; it does not check its validity
with the server.

On Unix, credential writes and temporary media use private staging directories
(`0700`) and files (`0600`) before writing sensitive content. Windows relies on
the selected directories' inherited ACLs; keep configuration and temporary
storage in locations private to the account. Browser authorization accepts
HTTPS URLs and loopback HTTP URLs. WSS uploads verify the certificate chain
and hostname.

Run `mix precommit` before proposing a change. It includes formatter, strict
Credo, Hex retirement/advisory checks, MixAudit, Sobelow, and tests. The CI and
release workflows enforce the same gate. Sobelow exceptions are documented at
individual functions; changes to those functions require reviewing the stated
trust boundary and associated regression tests.

`webhooks verify` checks the supplied raw body and signature. It returns the
signed timestamp but does not enforce a freshness window or prevent replay;
callers must handle those requirements in their webhook receiver. These
descriptions explain the current behavior and do not exclude related defects
from review.
