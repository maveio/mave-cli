"""Exercise the shipped CLI with only OS utilities on PATH and synthetic credentials."""

import argparse
import base64
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import termios
import threading
import time
import unicodedata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    token = "synthetic-package-token"
    requests = []
    authorizations = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.path == "/api/v1/cli/authorizations"
            assert self.headers.get("Authorization") is None
            authorizations.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            requests.append((self.path, self.headers.get("Authorization")))
            body = b'{"data":[]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    with tempfile.TemporaryDirectory(prefix="mave-package-test-") as directory:
        root = Path(directory)
        binary = root / "mave"
        shutil.copy2(args.binary, binary)
        env = {key: value for key, value in os.environ.items() if not key.startswith(("MAVE_", "ERL_", "ELIXIR_"))}
        env.update(PATH="/usr/bin:/bin", HOME=str(root), XDG_DATA_HOME=str(root / "data"))

        def run(arguments, config="config", value=None):
            return subprocess.run([str(binary), *arguments], cwd=root, env=dict(env, MAVE_CONFIG_HOME=str(root / config)), input=value, text=True, capture_output=True, timeout=60)

        # Every run uses a fresh home so Burrito cannot reuse another build's runtime.
        result = run(["--help"])
        assert result.returncode == 0 and "mave videos list" in result.stdout, result.stderr
        result = run(["--version"])
        assert result.returncode == 0 and result.stdout.strip() == args.version, result.stdout
        result = run(["--invalid-option"])
        assert result.returncode == 1 and "Error: invalid option" in result.stderr, result.stderr
        result = run(["upload-token", "test-subject", "--token", "test-secret"])
        assert result.returncode == 0, result.stderr
        signed = json.loads(result.stdout)
        header, payload, signature = signed["token"].split(".")
        expected = hmac.new(b"test-secret", f"{header}.{payload}".encode(), hashlib.sha256).digest()
        assert base64.urlsafe_b64encode(expected).decode().rstrip("=") == signature
        assert signed["subject"] == "test-subject"

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        endpoint = f"http://127.0.0.1:{server.server_port}/api/v1/"
        login = ["auth", "login", "--no-browser", "--base-url", endpoint]
        try:
            result = run(["auth", "login", "--base-url", endpoint], config="browser-login", value=f"{token}\n")
            assert result.returncode == 0 and token not in result.stdout + result.stderr, result.stderr
            assert len(authorizations) == 1
            metadata = authorizations[0]
            assert metadata["client"] == "mave-cli" and metadata["version"] == args.version
            name = metadata.get("device_name")
            assert isinstance(name, str) and 0 < len(name) <= 160 and name == name.strip(), metadata
            assert all(unicodedata.category(character) not in ("Cc", "Cf") for character in name), metadata

            result = run(login, value=f"  {token}  \n")
            assert result.returncode == 0 and token not in result.stdout + result.stderr
            saved = root / "config/mave/config.json"
            assert json.loads(saved.read_text()) == {"token": token, "api_base_url": endpoint.rstrip("/")}
            assert saved.stat().st_mode & 0o777 == 0o600
            for resource in ("videos", "collections"):
                result = run([resource, "list", "--base-url", endpoint])
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout) == {"data": []}
            assert len(requests) == 2 and all(auth == f"Bearer {token}" for _, auth in requests)
            result = run(["auth", "status", "--base-url", "http://different.test/api/v1/"])
            assert result.returncode == 1 and "Error: stored token belongs to a different server" in result.stderr, result.stderr
            for label, value in (("blank", "  \n"), ("eof", "")):
                assert run(login, config=label, value=value).returncode == 1
                assert not (root / label / "mave/config.json").exists()

            for label, value, expected_status in (("success", token.encode() + b"\n", 0), ("blank", b"  \n", 1), ("eof", b"\x04", 1)):
                config = root / f"tty-{label}"
                child_env = dict(env, MAVE_CONFIG_HOME=str(config))
                pid, master = pty.fork()
                if pid == 0:
                    os.execve(str(binary), [str(binary), *login], child_env)
                output = b""
                sent = False
                hidden = False
                status = None
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    readable, _, _ = select.select([master], [], [], 0.1)
                    if readable:
                        try:
                            output += os.read(master, 65536)
                        except OSError:
                            pass
                    if not sent and b"Mave API token: " in output:
                        hidden = not bool(termios.tcgetattr(master)[3] & termios.ECHO)
                        os.write(master, value)
                        sent = True
                    finished, raw_status = os.waitpid(pid, os.WNOHANG)
                    if finished:
                        status = os.waitstatus_to_exitcode(raw_status)
                        break
                if status is None:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)
                restored = bool(termios.tcgetattr(master)[3] & termios.ECHO)
                os.close(master)
                assert sent and status == expected_status, f"PTY {label} failed: {output!r}"
                assert hidden and token.encode() not in output and restored, f"PTY {label}: token echo or unrestored terminal"
                assert (config / "mave/config.json").exists() == (expected_status == 0)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()
    print("Standalone smoke tests passed: startup, JSON, crypto, HTTP, device metadata, saved login, server binding, permissions, piped input and hidden terminal input")


if __name__ == "__main__":
    main()
