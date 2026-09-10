# Using Mave CLI

[Back to the README](../README.md)

## Everyday commands

```sh
mave login
mave videos list --format table
mave videos get VIDEO_ID
mave videos upload https://example.com/video.mp4 --wait
mave videos upload ./local-video.mov --wait
mave collections create --name "Product videos"
mave spaces create --domain video.example.com
```

`mave login` (also available as `mave auth login`) opens a short-lived
authorization page in your browser. After you approve the CLI for a space, the
resulting API token is stored locally. If the connected Mave server does not
support browser authorization yet, or the authorization endpoint cannot be
reached, the CLI falls back to a hidden interactive API-token prompt. You can
choose that prompt directly with `mave login --no-browser`; positional tokens
and `--token` remain supported for automation and staged rollouts.

If a login is already saved for the selected server, either login command reports
that you are already logged in and exits without opening a browser or creating
another API key. Run `mave logout` first to replace the login or recover
from a revoked key. This also applies when supplying a token manually. When
`MAVE_TOKEN` is set, login uses that existing authentication instead; unset the
variable before changing to a saved or browser login. A login saved for a
different server does not prevent logging in to the selected server.

`mave logout` removes the locally saved login. The longer `mave auth login` and
`mave auth logout` commands remain available as aliases; use `mave auth status`
to inspect the current authentication source.

Browser login also sends the computer name (the macOS computer name, or the
hostname) so the connection can be recognized under API Keys in settings. If no
usable name is available, it is omitted. Existing keys keep their original
metadata; log out and log in again to create a connection with the computer name.

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

Token precedence is `--token`, followed by `MAVE_TOKEN`, followed by the locally stored token. On Unix, `mave login` writes the token with `0600` permissions to `${MAVE_CONFIG_HOME:-${XDG_CONFIG_HOME:-~/.config}}/mave/config.json`. For stricter secret storage, prefer your CI platform's environment-variable mechanism.

Run `mave --help` to see all commands. JSON is the default output format; add `--format table` for human-readable tables.

## Import from Vimeo

**Experimental:** automated tests cover the importer using simulated Vimeo and
Mave responses. A complete live import, including playable videos in Mave, has
not yet been verified. Start with `--dry-run` and a small test folder.

Import videos into the selected Mave space with their **titles and folder
structure**, including subfolders and empty folders. The CLI sends video file
links to Mave's existing import API; Mave fetches and processes the videos.

Run `mave import` to list available importers, or `mave import vimeo --help`
for Vimeo setup and options. Importing starts with `mave import vimeo`.

```sh
mave login
mave import vimeo --dry-run --format table
mave import vimeo
```

When no Vimeo token is saved and `VIMEO_ACCESS_TOKEN` is not set, the importer shows a link to
[your Vimeo apps](https://developer.vimeo.com/apps) and asks for a token using
hidden input. Select an existing app or create one, then choose
**Authentication → Generate Access Token → Authenticated (you)**. Enable
**Public**, **Private**, and **Video Files**, select **Generate**, and paste the
token into the CLI. The CLI validates it with Vimeo and saves it for subsequent
imports. Signing in to Vimeo in your browser does not authenticate
the CLI. See [Vimeo's token setup guide](https://help.vimeo.com/hc/en-us/articles/12427789081745-How-to-generate-a-personal-access-token).

For automation, set `VIMEO_ACCESS_TOKEN` instead. The token needs the `public`, `private`, and
`video_files` scopes. Transferring video files requires a Vimeo **Standard,
Advanced, Pro, Business, Premium, or Enterprise** plan; Free, Basic, Starter,
and Plus do not provide the file-link access used by this importer.
See [Vimeo's download-link documentation](https://help.vimeo.com/hc/en-us/articles/12427806914577-About-video-file-download-links-from-the-API).
The Vimeo token is used only for Vimeo API requests. Tokens entered at the prompt
are saved atomically with `0600` permissions on Unix, alongside the Mave login in
`${MAVE_CONFIG_HOME:-${XDG_CONFIG_HOME:-~/.config}}/mave/vimeo.json`.
`VIMEO_ACCESS_TOKEN` takes precedence over the saved token and is never persisted.

Manage this login through the importer:

```sh
mave import vimeo login   # Optional: save a token before your first import
mave import vimeo status  # Show whether the token comes from the environment or a file
mave import vimeo logout  # Remove the saved Vimeo token
```

These commands do not require a Mave login. Repeated Vimeo login keeps the existing
token; log out first to replace it. Logout removes only the local Vimeo token,
preserving your Mave login and import progress. It does not revoke the token at
Vimeo. If `VIMEO_ACCESS_TOKEN` is set, logout explains that you also need to unset
that variable. Plain `mave logout` continues to remove only the Mave login.
A first import with `--dry-run` can save the login, but never writes import progress
or creates videos or collections.

```sh
# Import a folder and its descendants, including the selected folder itself
mave import vimeo --folder 12345

# Put the imported hierarchy inside an existing Mave collection
mave import vimeo --collection MAVE_COLLECTION_ID

# Preview without creating collections, submitting videos, or saving state
mave import vimeo --dry-run --format table

# Resume with the same source selection and destination
mave import vimeo --resume

# Wait until each video is playable, with a timeout per video
mave import vimeo --wait --timeout 1800
```

Folders become Mave collections. Videos without a folder stay at the destination
root (or in `--collection`). Folder identity comes from Vimeo IDs, so folders
with the same name remain separate. Selecting `--folder` imports its subtree
without importing its ancestors. Existing Mave collections are not merged by
name. Only video titles and folder names are copied as metadata.

The importer fetches a fresh file link immediately before submitting each video.
It prefers an available source file, otherwise the highest-resolution available
video file. Originals are not guaranteed to be available. Vimeo read requests
retry temporary failures. On HTTP 429, the CLI pauses until Vimeo's `Retry-After`
or `X-RateLimit-Reset` allows another request, using the later value if both are
present. Without a usable reset header it waits 60 seconds. The wait is reported
on stderr, including during login, and does not prompt for the token again while
retrying. See [Vimeo's rate-limit guidance](https://help.vimeo.com/hc/en-us/articles/12427783954065-Rate-limits).

There are at most three retries per request. If a cooldown exceeds five minutes
or the retries are exhausted, the command stops and reports when to try again.
An import stops requesting further videos and preserves progress; repeat the
same command with `--resume` after the cooldown. During first login, the token is
saved only after Vimeo validates it; if validation still fails, the error explains
that it has not been saved yet. Mave create requests are not retried
automatically when their outcome is uncertain.

By default the command finishes after Mave has accepted the imports; `submitted`
does not mean playback is ready. Use `--wait` to verify playback, or
`mave import vimeo --resume --wait` to check previously submitted videos.
Unavailable videos are reported as `failed` while the remaining videos continue.
The command exits with status `1` if any video failed. Progress goes to stderr,
with results on stdout as JSON or `--format table`.

### Testing without a paid Vimeo plan

Vimeo's [general API is available on free accounts](https://help.vimeo.com/hc/en-us/articles/12427702473105-API-technical-and-developer-prerequisites).
You can test login and `mave import vimeo --dry-run --format table` to check titles
and the folders your account can access. The preview does not request video file
links or submit videos, so a successful preview does not verify a full import.

For complete verification, use a small folder in an eligible account, such as a
customer's test folder, and a Mave test space. Include two short videos and a
subfolder, import with `--folder ID --wait`, then check titles, nesting and playback.
Repeat with the same folder and `--resume --wait` to confirm videos are not duplicated.
The account owner can run these commands themselves without sharing their token.

### Resume state

The CLI saves Vimeo-to-Mave IDs under the same configuration directory as your
Mave login, in `mave/imports/vimeo-<hash>.json`. The result includes `state_file`.
Use `--state-file FILE` to choose a path. The state is bound to the Vimeo account,
Mave server and space, selected Vimeo folder, and destination collection. Repeat
the same options with `--resume`; saved IDs are reused. A different state file
starts a separate import. Run only one importer against a given state file at a
time, and keep the state file to avoid importing the same library twice.

State is written atomically with private file permissions and contains no access
tokens or signed file links. An existing state file is never reset automatically.
Videos that could not supply a file link are retried on resume. Videos already
accepted by Mave retain their IDs even if waiting for playback failed.

If a process stops during a create request, the state can contain a `pending`
item. The server might have created it without the CLI receiving the ID, so
resuming stops instead of risking a duplicate. Check the destination in Mave:

1. If the item exists, add its Mave ID to the state's `folders` or `videos`
   mapping under the `source_id` shown in `pending`.
2. If the item definitely was not created, leave that mapping unchanged.
3. Set `pending` to `null`, save the file, and run the same command with `--resume`.

For example, a pending video with `source_id` `12345` that exists in Mave is
reconciled by adding `"12345": "MAVE_VIDEO_ID"` to `videos` and clearing `pending`.
Do not clear it until you have checked whether the request succeeded.

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
`mave login` against the intended server. Use a separate `MAVE_CONFIG_HOME`
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
