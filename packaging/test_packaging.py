import hashlib
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import build_runtime
import package
import setup_zig
import verify_native


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.input = self.root / "input"
        self.input.mkdir()
        self.output = self.root / "output"

    def fixture(self, target, **overrides):
        data = b"synthetic unit-test executable"
        info = {
            "version": "0.1.0", "target": target,
            "source_commit": "a" * 40, "source_dirty": False,
            "mix_lock_sha256": "b" * 64,
            "binary_sha256": hashlib.sha256(data).hexdigest(),
            "runtime": {"sources": {"otp": "29.0.6"}, "builder_sha256": "c" * 64},
        }
        info.update(overrides)
        info["archive"] = f"mave-{info['version']}-{target}.tar.gz"
        path = self.input / info["archive"]
        with tarfile.open(path, "w:gz") as bundle:
            for name, content in (("mave", data), ("build-info.json", json.dumps(info).encode())):
                member = tarfile.TarInfo(name)
                member.size = len(content)
                bundle.addfile(member, io.BytesIO(content))
        info["sha256"] = package.sha256(path)
        (self.input / f"{target}.json").write_text(json.dumps(info))

    def complete(self):
        for target in package.TARGETS:
            self.fixture(target)

    def test_missing_target_cannot_produce_formula(self):
        self.fixture("macos_arm64")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            package.collect(self.input, self.output)
        self.assertFalse(self.output.exists())

    def test_checksum_mismatch_stops_collection(self):
        self.complete()
        (self.input / "mave-0.1.0-macos_arm64.tar.gz").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            package.collect(self.input, self.output)

    def test_different_source_commits_stop_collection(self):
        self.complete()
        self.fixture("linux_arm64", source_commit="d" * 40)
        with self.assertRaisesRegex(ValueError, "source_commit"):
            package.collect(self.input, self.output)

    def test_different_versions_stop_collection(self):
        self.complete()
        self.fixture("linux_arm64", version="0.2.0")
        with self.assertRaisesRegex(ValueError, "version"):
            package.collect(self.input, self.output)

    def test_dirty_builds_cannot_be_published(self):
        self.complete()
        self.fixture("linux_arm64", source_dirty=True)
        with self.assertRaisesRegex(ValueError, "clean source"):
            package.collect(self.input, self.output, require_clean=True)

    def test_metadata_tampering_is_detected(self):
        self.complete()
        path = self.input / "macos_arm64.json"
        info = json.loads(path.read_text())
        info["source_commit"] = "e" * 40
        path.write_text(json.dumps(info))
        with self.assertRaisesRegex(ValueError, "manifest disagree"):
            package.collect(self.input, self.output)

    def test_formula_uses_all_real_checksums_without_erlang_dependency(self):
        self.complete()
        package.collect(self.input, self.output, require_clean=True)
        formula = (self.output / "mave.rb").read_text()
        self.assertNotIn("@VERSION@", formula)
        self.assertNotIn("_SHA256@", formula)
        self.assertNotIn('depends_on "erlang"', formula)
        for target in package.TARGETS:
            info = json.loads((self.input / f"{target}.json").read_text())
            self.assertIn(info["archive"], formula)
            self.assertIn(info["sha256"], formula)
        self.assertIn("mave.rb", (self.output / "SHA256SUMS").read_text())
        with self.assertRaisesRegex(ValueError, "empty output"):
            package.collect(self.input, self.output)

    def test_source_checksum_checked_before_extraction(self):
        source = self.root / "source.tar.gz"
        source.write_bytes(b"corrupt source")
        with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
            build_runtime.fetch_source({"url": "https://example.invalid/source.tar.gz", "sha256": "0" * 64}, self.root)


class ZigSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name) / "zig"

    def test_corrupt_download_is_not_extracted_or_executed(self):
        with patch("setup_zig.urllib.request.urlopen", return_value=io.BytesIO(b"corrupt archive")), patch("setup_zig.subprocess.check_output") as execute:
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                setup_zig.install("macos_arm64", self.output)
            execute.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_checked_archive_is_extracted_and_version_is_verified(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:xz") as archive:
            binary = tarfile.TarInfo("zig-aarch64-macos-0.16.0/zig")
            binary.size = 7
            archive.addfile(binary, io.BytesIO(b"fixture"))
        data = buffer.getvalue()
        spec = ("aarch64-macos", hashlib.sha256(data).hexdigest())
        with patch.dict(setup_zig.ARCHIVES, {"macos_arm64": spec}), patch("setup_zig.urllib.request.urlopen", return_value=io.BytesIO(data)), patch("setup_zig.subprocess.check_output", return_value="0.16.0\n"):
            setup_zig.install("macos_arm64", self.output)
        self.assertEqual(b"fixture", (self.output / "zig").read_bytes())


class NativeAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.binary = Path(self.temporary.name) / "native"
        self.lock = {"macos_minimum": "13.0", "linux_glibc_maximum": "2.35"}

    def macho(self):
        self.binary.write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C) + bytes(12))

    def elf(self):
        self.binary.write_bytes(b"\x7fELF" + bytes([2, 1]) + bytes(12) + struct.pack("<H", 183))

    def test_homebrew_libraries_and_newer_macos_are_rejected(self):
        self.macho()
        with patch("verify_native.subprocess.check_output", side_effect=["native:\n\t/opt/homebrew/opt/openssl/lib/libcrypto.3.dylib (compatibility version 3.0.0)\n", "minos 26.0"]):
            errors = verify_native.inspect_file(self.binary, "macos_arm64", self.lock)
        self.assertTrue(any("external library" in error for error in errors))
        self.assertTrue(any("requires macOS 26.0" in error for error in errors))

    def test_system_macos_libraries_are_accepted(self):
        self.macho()
        with patch("verify_native.subprocess.check_output", side_effect=["native:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n", "minos 13.0.0"]):
            self.assertEqual([], verify_native.inspect_file(self.binary, "macos_arm64", self.lock))

    def test_wrong_architecture_is_rejected(self):
        self.macho()
        with patch("verify_native.subprocess.check_output", return_value=""):
            errors = verify_native.inspect_file(self.binary, "macos_x86_64", self.lock)
        self.assertIn("wrong Mach-O architecture", errors)

    def test_external_linux_ssl_rpath_and_newer_glibc_are_rejected(self):
        self.elf()
        with patch("verify_native.subprocess.check_output", side_effect=["(NEEDED) [libcrypto.so.3]\n(RUNPATH) [/build/lib]", "GLIBC_2.38"]):
            errors = verify_native.inspect_file(self.binary, "linux_arm64", self.lock)
        self.assertEqual(3, len(errors))

    def test_linux_baseline_is_accepted(self):
        self.elf()
        with patch("verify_native.subprocess.check_output", side_effect=["(NEEDED) [libc.so.6]", "GLIBC_2.17 GLIBC_2.35"]):
            self.assertEqual([], verify_native.inspect_file(self.binary, "linux_arm64", self.lock))


if __name__ == "__main__":
    unittest.main()
