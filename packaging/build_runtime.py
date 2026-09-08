"""Build a native OTP runtime with static OpenSSL, outside the system installation."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent


def fetch_source(spec, work):
    archive = work / spec["url"].rsplit("/", 1)[1]
    if not archive.exists():
        print(f"Downloading {archive.name}", flush=True)
        partial = archive.with_suffix(archive.suffix + ".partial")
        with urllib.request.urlopen(spec["url"], timeout=60) as source, partial.open("wb") as out:
            shutil.copyfileobj(source, out)
        partial.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != spec["sha256"]:
        raise RuntimeError(f"Checksum mismatch for {archive.name}")
    with tarfile.open(archive) as source:
        # Source archives are pinned, and extraction also rejects unsafe paths/links.
        destination = work / archive.name.removesuffix(".tar.gz")
        if not destination.exists():
            staging = work / (archive.name + ".unpacked")
            staging.mkdir(exist_ok=True)
            source.extractall(staging, filter="data")
            roots = list(staging.iterdir())
            if len(roots) != 1 or not roots[0].is_dir():
                raise RuntimeError(f"Unexpected source layout in {archive.name}")
            roots[0].rename(destination)
            staging.rmdir()
    return destination


def run(args, directory, env, log):
    print(f"Building: {' '.join(map(str, args))}", flush=True)
    with log.open("ab") as output:
        subprocess.run(args, cwd=directory, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)


def copy_notices(source, destination):
    for path in source.rglob("*"):
        if path.is_file() and path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "AUTHORS")):
            target = destination / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    lock = json.loads((ROOT / "runtime.lock.json").read_text())
    system = platform.system()
    arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}.get(platform.machine())
    if system not in ("Darwin", "Linux") or not arch:
        parser.error("Use a native macOS or Linux ARM64/x86-64 build host")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    work = args.work.resolve()
    output = args.output.resolve()
    fingerprint = {
        "sources": lock,
        "system": system,
        "architecture": arch,
        "builder_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    marker = output / "build-info.json"
    if marker.exists() and json.loads(marker.read_text()) == fingerprint:
        print(f"Using verified runtime build in {output}")
        return
    if output.exists():
        parser.error("Output exists with different build inputs; choose an empty output directory")
    work.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for name in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS", "ERL_TOP"):
        env.pop(name, None)
    env["CFLAGS"] = "-O2"
    env["CXXFLAGS"] = "-O2"
    if system == "Darwin":
        env.update(CC="/usr/bin/clang", CXX="/usr/bin/clang++", MACOSX_DEPLOYMENT_TARGET=lock["macos_minimum"])
        ssl_target = "darwin64-arm64-cc" if arch == "aarch64" else "darwin64-x86_64-cc"
    else:
        ssl_target = "linux-aarch64" if arch == "aarch64" else "linux-x86_64"
    ssl_source = fetch_source(lock["openssl"], work)
    otp_source = fetch_source(lock["otp"], work)
    ssl_prefix = work / "openssl-install"
    otp_prefix = work / "otp-install"
    log = work / "build.log"
    run(["./Configure", ssl_target, "no-shared", "no-tests", "no-module", "no-engine", "no-legacy", f"--prefix={ssl_prefix}", "--libdir=lib"], ssl_source, env, log)
    run(["make", f"-j{args.jobs}"], ssl_source, env, log)
    run(["make", "install_sw"], ssl_source, env, log)
    run([
        "./configure", f"--prefix={otp_prefix}", f"--with-ssl={ssl_prefix}",
        "--disable-dynamic-ssl-lib", "--with-ssl-rpath=no", "--disable-jit",
        "--without-termcap", "--without-wx", "--without-javac", "--without-odbc",
        "--enable-builtin-zlib", "--enable-builtin-zstd", "--disable-saved-compile-time",
    ], otp_source, env, log)
    run(["make", f"-j{args.jobs}"], otp_source, env, log)
    run(["make", "install"], otp_source, env, log)
    # Burrito expects an archive-style parent containing otp/erts-* and otp/lib.
    output.mkdir(parents=True)
    shutil.copytree(otp_prefix / "lib/erlang", output / "otp", symlinks=True)
    copy_notices(otp_source, output / "licenses/erlang")
    copy_notices(ssl_source, output / "licenses/openssl")
    marker.write_text(json.dumps(fingerprint, indent=2) + "\n")
    print(f"Runtime ready: BURRITO_CUSTOM_ERTS={output}", flush=True)


if __name__ == "__main__":
    main()
