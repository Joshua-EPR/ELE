"""Fail-closed regression tests for ELE autonomous release packaging.

No compiler or GitHub runner required: only simulated build outputs are used.
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ele_distribution", ROOT / "scripts" / "package_distribution.py"
)
dist = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dist)


class FixpointTests(unittest.TestCase):
    def test_distribution_requires_an_explicit_verified_seed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "compiler-l/src/main_driver.l"
            src.parent.mkdir(parents=True)
            src.write_text("flow main() => Int { give 0 }", encoding="utf-8")
            work = root / "build"
            work.mkdir()
            with mock.patch.object(dist.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "requires --driver-path"):
                    dist.build_autonomous_compiler(root, "windows", work)
                run.assert_not_called()

    def test_package_cli_requires_seed_path(self):
        with mock.patch.object(sys, "argv", ["package_distribution.py", "--target", "linux"]):
            with self.assertRaises(SystemExit) as raised:
                dist.main()
        self.assertEqual(raised.exception.code, 2)

    def test_identical_generations_are_accepted(self):
        with tempfile.TemporaryDirectory() as td:
            gen2, gen3 = Path(td) / "gen2", Path(td) / "gen3"
            gen2.write_bytes(b"ELE-generation")
            gen3.write_bytes(b"ELE-generation")
            self.assertEqual(dist.verify_fixpoint(gen2, gen3), gen3)

    def test_different_generations_abort(self):
        with tempfile.TemporaryDirectory() as td:
            gen2, gen3 = Path(td) / "gen2", Path(td) / "gen3"
            gen2.write_bytes(b"ELE-gen2")
            gen3.write_bytes(b"ELE-gen3")
            with self.assertRaisesRegex(RuntimeError, "Gen 2 != Gen 3"):
                dist.verify_fixpoint(gen2, gen3)

    def test_missing_generation_aborts(self):
        with tempfile.TemporaryDirectory() as td:
            gen2, gen3 = Path(td) / "gen2", Path(td) / "gen3"
            gen2.write_bytes(b"ELE-gen2")
            with self.assertRaisesRegex(RuntimeError, "missing Gen 2 or Gen 3"):
                dist.verify_fixpoint(gen2, gen3)

    def test_builds_gen1prime_gen2_gen3_and_accepts_gen2_fixpoint(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "compiler-l/src/main_driver.l"
            src.parent.mkdir(parents=True)
            src.write_text("flow main() => Int { give 0 }", encoding="utf-8")
            gen1 = root / "gen1"
            gen1.write_bytes(b"test driver")
            work = root / "build"
            work.mkdir()

            invocations = []

            def fake_run(args, **_kwargs):
                invocations.append(args)
                output = Path(args[-1])
                generation = len(invocations)
                output.write_bytes({1: b"ELE-gen1prime", 2: b"ELE-gen2", 3: b"ELE-gen2"}[generation])
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            target = "windows" if sys.platform == "win32" else "linux"
            with mock.patch.object(dist.subprocess, "run", side_effect=fake_run):
                result = dist.build_autonomous_compiler(root, target, work, gen1)

            self.assertEqual(len(invocations), 3)
            gen1prime, gen2, gen3 = [Path(call[-1]) for call in invocations]
            self.assertEqual([Path(call[0]) for call in invocations], [gen1, gen1prime, gen2])
            self.assertIn("gen1prime", gen1prime.name)
            self.assertIn("gen2", gen2.name)
            self.assertIn("gen3", gen3.name)
            self.assertEqual(gen1prime.read_bytes(), b"ELE-gen1prime")
            self.assertEqual(gen2.read_bytes(), b"ELE-gen2")
            self.assertEqual(gen3.read_bytes(), b"ELE-gen2")
            self.assertEqual(result, gen3)

    def test_gen2_gen3_mismatch_aborts_after_three_builds(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "compiler-l/src/main_driver.l"
            src.parent.mkdir(parents=True)
            src.write_text("flow main() => Int { give 0 }", encoding="utf-8")
            gen1 = root / "gen1"
            gen1.write_bytes(b"test driver")
            work = root / "build"
            work.mkdir()
            invocations = []

            def fake_run(args, **_kwargs):
                invocations.append(args)
                Path(args[-1]).write_bytes((b"ELE-gen1prime", b"ELE-gen2", b"ELE-gen3")[len(invocations) - 1])
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            target = "windows" if sys.platform == "win32" else "linux"
            with mock.patch.object(dist.subprocess, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "Gen 2 != Gen 3"):
                    dist.build_autonomous_compiler(root, target, work, gen1)
            self.assertEqual(len(invocations), 3)

    def test_failed_gen3_rebuild_cannot_fall_back_to_gen2(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "compiler-l/src/main_driver.l"
            src.parent.mkdir(parents=True)
            src.write_text("flow main() => Int { give 0 }", encoding="utf-8")
            gen1 = root / "gen1"
            gen1.write_bytes(b"test driver")
            work = root / "build"
            work.mkdir()
            invocations = []

            def fake_run(args, **_kwargs):
                invocations.append(args)
                if len(invocations) < 3:
                    Path(args[-1]).write_bytes(f"ELE-gen{len(invocations)}".encode())
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                return SimpleNamespace(returncode=1, stdout="", stderr="failed")

            target = "windows" if sys.platform == "win32" else "linux"
            with mock.patch.object(dist.subprocess, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "Gen 3 self-rebuild failed"):
                    dist.build_autonomous_compiler(root, target, work, gen1)
            self.assertEqual(len(invocations), 3)

    def test_cross_target_without_execution_aborts(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "compiler-l/src/main_driver.l"
            src.parent.mkdir(parents=True)
            src.write_text("flow main() => Int { give 0 }", encoding="utf-8")
            gen1 = root / "gen1"
            gen1.write_bytes(b"test driver")
            work = root / "build"
            work.mkdir()
            target = "linux" if sys.platform == "win32" else "windows"

            def fake_run(args, **_kwargs):
                Path(args[-1]).write_bytes(b"ELE-gen2")
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with mock.patch.object(dist.subprocess, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "Cannot verify"):
                    dist.build_autonomous_compiler(root, target, work, gen1)


if __name__ == "__main__":
    unittest.main()

