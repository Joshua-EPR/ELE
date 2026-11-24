from __future__ import annotations

import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from tools.audit_stage0_paths import (
    audit_files,
    audit_repository,
    discover_official_files,
    main,
)


class Stage0PathAuditTests(unittest.TestCase):
    def test_inventoried_active_reference_is_reported_but_not_a_violation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workflow = root / ".github/workflows/native.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("run: cargo test -p project-l\n", encoding="utf-8")
            result = audit_files(root, [workflow], allowlist={
                ".github/workflows/native.yml": {
                    "cargo": "legacy test runner", "project-l": "legacy crate"
                }
            })
        self.assertEqual(len(result.findings), 2)
        self.assertEqual(result.violations, ())
        self.assertTrue(all(f.classification == "active" and f.allowed for f in result.findings))

    def test_new_active_reference_fails_enforcement(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workflow = root / ".github/workflows/new.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("run: rustc source.rs\n", encoding="utf-8")
            result = audit_files(root, [workflow], allowlist={})
        self.assertEqual(len(result.violations), 1)
        self.assertEqual(result.violations[0].token, "rustc")
        self.assertEqual(result.violations[0].line, 1)

    def test_uninventoried_token_fails_even_in_an_allowlisted_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workflow = root / ".github/workflows/distribution.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("run: rustc compiler.rs\n", encoding="utf-8")
            result = audit_files(root, [workflow])
        self.assertEqual(len(result.violations), 1)
        self.assertEqual(result.violations[0].token, "rustc")

    def test_new_occurrence_in_an_allowlisted_path_exceeds_pinned_count(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workflow = root / ".github/workflows/native.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("run: cargo test\n# new cargo reference\n", encoding="utf-8")
            result = audit_files(
                root,
                [workflow],
                allowlist={".github/workflows/native.yml": {"cargo": "legacy runner"}},
                allowed_counts={(".github/workflows/native.yml", "cargo"): 1},
            )
        self.assertEqual(len(result.violations), 1)
        self.assertEqual(result.violations[0].line, 2)

    def test_enforce_cli_returns_nonzero_for_unlisted_active_reference(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workflow = root / ".github/workflows/new.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("run: cargo test\n", encoding="utf-8")
            output = StringIO()
            with patch("sys.argv", ["audit_stage0_paths.py", "--root", str(root), "--enforce"]), redirect_stdout(output):
                status = main()
        self.assertEqual(status, 1)
        self.assertIn("FAIL .github/workflows/new.yml:1: cargo", output.getvalue())

    def test_unreadable_official_file_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workflow = root / ".github/workflows/bad.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_bytes(b"\xff\xfe\xfa")
            result = audit_files(root, [workflow])
        self.assertEqual(len(result.violations), 1)
        self.assertEqual(result.violations[0].token, "read-error")

    def test_historical_file_is_separate_from_active_failures(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            history = root / "STAGE0_PROGRESS.md"
            history.write_text("cargo and Cranelift were used historically.\n", encoding="utf-8")
            result = audit_files(root, [history], allowlist={})
        self.assertEqual(result.violations, ())
        self.assertEqual({f.classification for f in result.findings}, {"historical"})

    def test_unscoped_file_is_not_discovered(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "tests/fixtures/old.rs"
            source.parent.mkdir(parents=True)
            source.write_text("cargo Stage 0 Cranelift\n", encoding="utf-8")
            workflow = root / ".github/workflows/build.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("name: Build\n", encoding="utf-8")
            self.assertEqual(discover_official_files(root), (workflow,))

    def test_binary_seed_archives_are_not_decoded_as_text(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            seeds = root / "scripts/bootstrap/seeds"
            seeds.mkdir(parents=True)
            archive = seeds / "ele-seed-pe.zip"
            archive.write_bytes(b"\x00\xff\x80")
            readme = seeds / "README.md"
            readme.write_text("Seed archive provenance.\n", encoding="utf-8")
            self.assertEqual(discover_official_files(root), (readme,))

    def test_current_official_routes_have_no_uninventoried_references(self):
        result = audit_repository()
        self.assertEqual(result.violations, ())


if __name__ == "__main__":
    unittest.main()
