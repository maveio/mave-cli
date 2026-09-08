"""Install the pinned Zig compiler directly from its verified upstream archive."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "0.16.0"
ARCHIVES = {
    "macos_arm64": ("aarch64-macos", "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"),
    "macos_x86_64": ("x86_64-macos", "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7"),
    "linux_arm64": ("aarch64-linux", "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17"),
    "linux_x86_64": ("x86_64-linux", "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"),
}


def install(target, output):
    triplet, digest = ARCHIVES[target]
    name = f"zig-{triplet}-{VERSION}"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("Choose an empty Zig output path")
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        temporary = Path(directory)
        archive = temporary / "zig.tar.xz"
        url = f"https://ziglang.org/download/{VERSION}/{name}.tar.xz"
        print(f"Downloading {url}", flush=True)
        with urllib.request.urlopen(url, timeout=60) as source, archive.open("wb") as destination:
            shutil.copyfileobj(source, destination)
        with archive.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != digest:
                raise ValueError("Zig archive checksum mismatch")
        with tarfile.open(archive) as source:
            source.extractall(temporary / "unpacked", filter="data")
        extracted = temporary / "unpacked" / name
        actual = subprocess.check_output([str(extracted / "zig"), "version"], text=True).strip()
        if actual != VERSION:
            raise ValueError(f"Expected Zig {VERSION}, got {actual}")
        extracted.rename(output)
    print(f"Verified Zig {VERSION}: {output}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=ARCHIVES, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads((Path(__file__).parent / "runtime.lock.json").read_text())
    if lock["zig"] != VERSION:
        parser.error("Update the Zig download checksums to match runtime.lock.json")
    output = args.output.resolve()
    install(args.target, output)
    if os.environ.get("GITHUB_PATH"):
        with open(os.environ["GITHUB_PATH"], "a") as path_file:
            path_file.write(str(output) + "\n")


if __name__ == "__main__":
    main()
