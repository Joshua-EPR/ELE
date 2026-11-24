from __future__ import annotations

import json
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEEDS = ROOT / "scripts" / "bootstrap" / "seeds"
from tools.verify_seed_archive import verify_image, verify_seed_archive  # noqa: E402


class SeedArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((SEEDS / "manifest.json").read_text(encoding="utf-8"))

    def test_both_versioned_seeds_match_hash_and_format_pins(self):
        for target, record in self.manifest["targets"].items():
            with self.subTest(target=target):
                seed = verify_seed_archive(SEEDS / record["archive"], target, self.manifest)
                self.assertEqual(len(seed), record["seed_size"])

    def test_tampered_archive_is_rejected(self):
        record = self.manifest["targets"]["pe"]
        original = (SEEDS / record["archive"]).read_bytes()
        tampered = bytearray(original)
        tampered[-1] ^= 1
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / record["archive"]
            path.write_bytes(tampered)
            with self.assertRaisesRegex(ValueError, "archive SHA-256"):
                verify_seed_archive(path, "pe", self.manifest)

    def test_archive_for_other_target_is_rejected(self):
        elf = SEEDS / self.manifest["targets"]["elf"]["archive"]
        with self.assertRaisesRegex(ValueError, "archive SHA-256"):
            verify_seed_archive(elf, "pe", self.manifest)

    def test_image_architecture_and_container_are_rejected(self):
        for target, malformed in (("elf", b"\x7fELF\x01\x01\x01" + b"\0" * 120),
                                  ("pe", b"MZ" + b"\0" * 126)):
            with self.subTest(target=target), self.assertRaises(ValueError):
                verify_image(malformed, target)

    def test_zip_with_extra_member_is_rejected(self):
        record = self.manifest["targets"]["elf"]
        seed = verify_seed_archive(SEEDS / record["archive"], "elf", self.manifest)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "seed.zip"
            with zipfile.ZipFile(path, "w") as bundle:
                bundle.writestr(record["seed_file"], seed)
                bundle.writestr(record["seed_file"] + ".sha256", record["seed_sha256"])
                bundle.writestr("unexpected", "not allowed")
            changed_manifest = json.loads(json.dumps(self.manifest))
            import hashlib
            changed_manifest["targets"]["elf"]["archive_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, "unexpected or missing"):
                verify_seed_archive(path, "elf", changed_manifest)


if __name__ == "__main__":
    unittest.main()
