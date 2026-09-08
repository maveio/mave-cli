"""Assemble standalone archives and a Homebrew formula from verified build artifacts."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ("macos_arm64", "macos_x86_64", "linux_arm64", "linux_x86_64")


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def project_version():
    return re.search(r'@version "([0-9]+\.[0-9]+\.[0-9]+)"', (ROOT / "mix.exs").read_text())[1]


def archive(binary, runtime, target, output):
    subprocess.run(["python3", str(ROOT / "packaging/verify_native.py"), str(binary), "--target", target], check=True)
    version = project_version()
    runtime_info = json.loads((runtime / "build-info.json").read_text())
    lock = json.loads((ROOT / "packaging/runtime.lock.json").read_text())
    if runtime_info["sources"] != lock:
        raise ValueError("Runtime does not match runtime.lock.json")
    if runtime_info["builder_sha256"] != sha256(ROOT / "packaging/build_runtime.py"):
        raise ValueError("Runtime was built with a different builder revision")
    expected = ("Darwin" if target.startswith("macos") else "Linux", "aarch64" if target.endswith("arm64") else "x86_64")
    if (runtime_info["system"], runtime_info["architecture"]) != expected:
        raise ValueError("Runtime and binary targets differ")
    output.mkdir(parents=True, exist_ok=True)
    name = f"mave-{version}-{target}.tar.gz"
    info = {
        "version": version, "target": target, "archive": name,
        "binary_sha256": sha256(binary), "runtime": runtime_info,
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
        "mix_lock_sha256": sha256(ROOT / "mix.lock"),
    }
    with tempfile.TemporaryDirectory() as directory:
        stage = Path(directory)
        shutil.copy2(binary, stage / "mave")
        (stage / "mave").chmod(0o755)
        for file in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT / file, stage / file)
        shutil.copytree(runtime / "licenses", stage / "licenses")
        for notice in (ROOT / "packaging/homebrew").iterdir():
            if notice.name.endswith(("-LICENSE", "-NOTICE")):
                shutil.copy2(notice, stage / "licenses" / notice.name)
        for dep in sorted((ROOT / "deps").iterdir()):
            for file in dep.iterdir():
                if file.is_file() and (file.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT")) or (dep.name == "nimble_pool" and file.name == "README.md")):
                    destination = stage / "licenses" / dep.name / file.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(file, destination)
        (stage / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
        with tarfile.open(output / name, "w:gz") as bundle:
            for file in sorted(stage.iterdir()):
                bundle.add(file, arcname=file.name)
    info["sha256"] = sha256(output / name)
    (output / f"{target}.json").write_text(json.dumps(info, indent=2) + "\n")
    print(f"Prepared {output / name}")


def collect(directory, output, require_clean=False):
    records = []
    for target in TARGETS:
        matches = list(directory.rglob(f"{target}.json"))
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one verified artifact for {target}")
        info = json.loads(matches[0].read_text())
        expected_name = f"mave-{info['version']}-{target}.tar.gz"
        if info["target"] != target or info["archive"] != expected_name:
            raise ValueError(f"Invalid artifact metadata for {target}")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", info["version"]):
            raise ValueError("Invalid release version")
        path = matches[0].parent / expected_name
        if sha256(path) != info["sha256"]:
            raise ValueError(f"Checksum mismatch for {path.name}")
        with tarfile.open(path) as bundle:
            embedded = json.load(bundle.extractfile("build-info.json"))
            if embedded != {key: value for key, value in info.items() if key != "sha256"}:
                raise ValueError("Archive and manifest disagree")
            if hashlib.sha256(bundle.extractfile("mave").read()).hexdigest() != info["binary_sha256"]:
                raise ValueError("Binary checksum mismatch")
        if require_clean and info["source_dirty"]:
            raise ValueError("Publication requires a clean source checkout")
        records.append((info, path))
    for key in ("version", "source_commit", "mix_lock_sha256", "source_dirty"):
        if len({item[key] for item, _ in records}) != 1:
            raise ValueError(f"Builds disagree on {key}")
    if len({json.dumps(item["runtime"]["sources"], sort_keys=True) for item, _ in records}) != 1:
        raise ValueError("Builds use different runtime versions")
    if len({item["runtime"]["builder_sha256"] for item, _ in records}) != 1:
        raise ValueError("Builds use different runtime builders")
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use an empty output directory to avoid stale release files")
    output.mkdir(parents=True, exist_ok=True)
    for _, path in records:
        shutil.copy2(path, output / path.name)
    version = records[0][0]["version"]
    formula = (ROOT / "packaging/homebrew/mave.rb.template").read_text().replace("@VERSION@", version)
    for item, _ in records:
        formula = formula.replace(f"@{item['target'].upper()}_SHA256@", item["sha256"])
    (output / "mave.rb").write_text(formula)
    (output / "build-info.json").write_text(json.dumps([item for item, _ in records], indent=2) + "\n")
    checksums = [f"{sha256(file)}  {file.name}" for file in sorted(output.iterdir()) if file.is_file() and file.name != "SHA256SUMS"]
    (output / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    print(f"All four targets verified; release files prepared in {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("archive")
    build.add_argument("--binary", type=Path, required=True)
    build.add_argument("--runtime", type=Path, required=True)
    build.add_argument("--target", choices=TARGETS, required=True)
    build.add_argument("--output", type=Path, required=True)
    gather = commands.add_parser("collect")
    gather.add_argument("--input", type=Path, required=True)
    gather.add_argument("--output", type=Path, required=True)
    gather.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    if args.command == "archive":
        archive(args.binary.resolve(), args.runtime.resolve(), args.target, args.output)
    else:
        collect(args.input, args.output, args.require_clean)


if __name__ == "__main__":
    main()
