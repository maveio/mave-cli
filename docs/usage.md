# Using Mave CLI

[Back to the README](../README.md)

## Everyday commands

```sh
mave auth login
mave videos list --format table
mave videos get VIDEO_ID
mave videos upload https://example.com/video.mp4 --wait
mave videos upload ./local-video.mov --wait
mave collections create --name "Product videos"
mave spaces create --domain video.example.com
```

`mave auth login` opens a short-lived authorization page in your browser. After you approve the CLI for a space, the resulting API token is stored locally. If the connected Mave server does not support browser authorization yet, or the authorization endpoint cannot be reached, the CLI gracefully falls back to a hidden interactive API-token prompt. You can choose that prompt directly with `mave auth login --no-browser`; positional tokens and `--token` remain supported for automation and staged rollouts.

Browser login also sends the computer name (the macOS computer name, or the
hostname) so the connection can be recognized under API Keys in settings. If no
usable name is available, it is omitted. Existing keys keep their original
metadata; log in again to create a connection with the computer name.

`videos upload` accepts either a URL or a local file. For URL input, the CLI first downloads the source locally and then uploads it directly to Mave using the resumable TUS protocol:

```sh
mave videos upload https://example.com/video.mp4
mave videos upload ./video.webm
```

This also supports sources such as Wikimedia that block Mave's server-side fetch. Downloads use an identifiable User-Agent. Uploads are split into TUS chunks and resume from Mave's `Upload-Offset` after a temporary network failure.

The older server-side import remains available explicitly:

```sh
mave videos create https://example.com/video.mp4
mave videos create --input-url https://example.com/video.mp4
```

During an interactive upload, the CLI waits by default until the first HLS rendition is playable. It reports downloaded bytes, exact TUS upload percentages, and rendition events on stderr. For CI or pipelines, enable waiting explicitly with `--wait`. Use `--no-wait` to stop after transferring the original file, `--no-progress` for quiet output, or `--timeout SECONDS` to change the default ten-minute limit. JSON output always remains clean on stdout.

```text
↓ Download [████████████░░░░░░░░░░░░]  50%  83.5 MiB / 167.0 MiB
↑ Upload   [██████████████████░░░░░░]  75%  125.3 MiB / 167.0 MiB
⠹ Processing: rendition ready: video · hls · 1920×1080
✓ video is playable
```

Authentication can also be configured without browser login or a configuration file:

```sh
export MAVE_TOKEN="..."
mave videos list | jq '.data[].id'
```

Bearer authentication is the default. Mave also documents Basic authentication; because a Mave API token is already the Base64-encoded `key:secret` pair, pass the same token with `--basic`:

```sh
mave videos list --basic
```

Token precedence is `--token`, followed by `MAVE_TOKEN`, followed by the locally stored token. On Unix, `auth login` writes the token with `0600` permissions to `${MAVE_CONFIG_HOME:-${XDG_CONFIG_HOME:-~/.config}}/mave/config.json`. For stricter secret storage, prefer your CI platform's environment-variable mechanism.

Run `mave --help` to see all commands. JSON is the default output format; add `--format table` for human-readable tables.

## Custom endpoints

Use the API, upload socket, TUS, and CDN addresses configured by your server
operator. The CLI accepts `--base-url`, `--socket-url`, `--upload-url`, and
`--cdn-base-url`. **`--base-url` only changes the API and browser-login
endpoint.** Set the socket and TUS URLs as well when uploading to a different
environment; otherwise those connections still use the managed service.

The CDN base URL can contain `{space}`, which expands to the five-character
space hash, for example `https://media.example.com/space-{space}`. It can also
be a fixed URL for one space. Use HTTPS/WSS for remote deployments; HTTP/WS is
available for local development.

Stored tokens are bound to the API base URL used at login. Switching servers
does not reuse the saved token. Older unbound logins must be saved again with
`mave auth login` against the intended server. Use a separate `MAVE_CONFIG_HOME`
for each environment to keep multiple logins. An explicit `--token` or
`MAVE_TOKEN` still applies to the server selected for that command.

## Command reference

### Videos and collections

```sh
mave videos list [--page N] [--per-page N] [--uploaded] [--collection ID] [--show-collections]
mave videos get ID
mave videos create [URL | --input-url URL] [--collection ID] [--wait]
mave videos upload FILE_OR_URL [--collection ID] [--wait]
mave videos wait ID [--timeout SECONDS]
mave videos update ID [--name NAME] [--collection ID | --root]
mave videos delete ID [--yes]

mave collections list [--page N] [--per-page N]
mave collections create --name NAME [--collection PARENT_ID]
mave collections update ID [--name NAME] [--collection PARENT_ID | --root]
mave collections delete ID [--yes]
```

### Spaces

The documented space-creation endpoint is available as:

```sh
mave spaces create --domain video.example.com
mave spaces create --domain video.example.com --return-key
```

Mave marks this API as a special feature that must first be enabled for the account. `--return-key` includes a new API key in the response; treat that output as a secret.

### Upload component tokens

Generate an HS256 JWT for the official `<mave-upload>` web component:

```sh
mave upload-token SPACE_ID
mave upload-token COLLECTION_ID --expires-in 900
mave upload-token EMBED_ID --expires-in 900
```

The subject follows Mave's upload semantics: a space creates a video, a collection creates a video inside that collection, and an embed replaces that video's source. The token is written as JSON to stdout, so a shell can safely select it with `jq -r .token`.

### Webhooks

Verify the raw request body against a complete `Mave-Signature` header:

```sh
export MAVE_WEBHOOK_SECRET="..."
mave webhooks verify event.json --signature 't=1785443715,v1=...'
printf '%s' "$RAW_BODY" | mave webhooks verify - --signature "$MAVE_SIGNATURE"
```

The command exits with status `0` for a valid signature and `1` for a mismatch. Its JSON result contains `valid` and `timestamp`. The raw payload bytes must be passed unchanged. `--secret` is supported, but `MAVE_WEBHOOK_SECRET` avoids exposing the secret in the process list.

### Public source files

A Mave combined embed ID contains the five-character space hash followed by the ten-character embed ID. The CLI can resolve the deterministic CDN URL, fetch its manifest, or download an asset listed by that manifest:

```sh
mave sources manifest ubg50Cq5Ilpnar1
mave sources url ubg50Cq5Ilpnar1 v8/thumbnail.jpg
mave sources download ubg50Cq5Ilpnar1 v8/h264_fhd.mp4 -o video.mp4
```

Downloads do not overwrite existing files unless `--yes` is supplied. Source commands use the public CDN and do not require an API token.
