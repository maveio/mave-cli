"""Reject native runtime dependencies that would make the CLI depend on build-host packages."""

import argparse
import json
from pathlib import Path
import re
import struct
import subprocess

LINUX_SYSTEM_LIBRARIES = {"libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1"}
MACHO_ARCH = {0x01000007: "x86_64", 0x0100000C: "arm64"}
ELF_ARCH = {62: "x86_64", 183: "arm64"}


def version(value):
    return tuple((list(map(int, value.split("."))) + [0, 0, 0])[:3])


def inspect_file(path, target, lock):
    with path.open("rb") as source:
        header = source.read(20)
    errors = []
    expected = "arm64" if target.endswith("arm64") else "x86_64"
    if header[:4] == b"\xcf\xfa\xed\xfe":
        if not target.startswith("macos_") or MACHO_ARCH.get(struct.unpack("<I", header[4:8])[0]) != expected:
            errors.append("wrong Mach-O architecture")
        dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
        for entry in dependencies:
            library = entry.strip().split(" (", 1)[0]
            if not library.startswith(("/usr/lib/", "/System/Library/")):
                errors.append(f"external library: {library}")
        commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
        for minimum in re.findall(r"\bminos\s+([0-9.]+)", commands):
            if version(minimum) > version(lock["macos_minimum"]):
                errors.append(f"requires macOS {minimum}, above the declared minimum")
    elif header[:4] == b"\x7fELF":
        if not target.startswith("linux_") or ELF_ARCH.get(struct.unpack("<H", header[18:20])[0]) != expected:
            errors.append("wrong ELF architecture")
        dynamic = subprocess.check_output(["readelf", "-d", str(path)], text=True)
        for library in re.findall(r"\(NEEDED\).*\[(.*?)\]", dynamic):
            if library not in LINUX_SYSTEM_LIBRARIES:
                errors.append(f"external library: {library}")
        for rpath in re.findall(r"\((?:RPATH|RUNPATH)\).*\[(.*?)\]", dynamic):
            if rpath:
                errors.append(f"unexpected library search path: {rpath}")
        versions = subprocess.check_output(["readelf", "--version-info", str(path)], text=True)
        for required in set(re.findall(r"\bGLIBC_([0-9.]+)", versions)):
            if version(required) > version(lock["linux_glibc_maximum"]):
                errors.append(f"requires glibc {required}, above the declared minimum")
    else:
        return None
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--target", choices=["macos_arm64", "macos_x86_64", "linux_arm64", "linux_x86_64"], required=True)
    args = parser.parse_args()
    lock = json.loads((Path(__file__).parent / "runtime.lock.json").read_text())
    files = [args.path] if args.path.is_file() else args.path.rglob("*")
    count = 0
    failures = []
    for path in files:
        if path.is_file():
            errors = inspect_file(path, args.target, lock)
            if errors is not None:
                count += 1
                failures.extend(f"{path}: {error}" for error in errors)
    if not count:
        failures.append("No native executables or libraries found")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Verified {count} native files: correct architecture, supported OS baseline, no external runtime packages")


if __name__ == "__main__":
    main()
