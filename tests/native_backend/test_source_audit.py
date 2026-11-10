"""Tests for development-only static source import inventory (not Stage 1)."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "ele_source_audit.py"
spec = importlib.util.spec_from_file_location("ele_source_audit", SCRIPT)
assert spec and spec.loader
import sys
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class SourceAuditTest(unittest.TestCase):
    def test_diamond_graph_deduplicates(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "main_sema.l").write_text("import a\nimport b\n", encoding="utf-8")
            (root / "a.l").write_text("import common\n", encoding="utf-8")
            (root / "b.l").write_text("import common\n", encoding="utf-8")
            (root / "common.l").write_text("fn value() -> Int { return 42 }", encoding="utf-8")
            report = module.audit(root)
            self.assertTrue(report.valid)
            self.assertEqual(len(report.reachable), 4)
            self.assertEqual(report.reachable[0], "common.l")
            self.assertEqual(report.reachable[-1], "main_sema.l")

    def test_cycle_and_missing_are_errors(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "main_sema.l").write_text("import a\nimport missing\n", encoding="utf-8")
            (root / "a.l").write_text("import main_sema\n", encoding="utf-8")
            report = module.audit(root)
            self.assertFalse(report.valid)
            self.assertEqual(len(report.cycles), 1)
            self.assertEqual(len(report.missing), 1)

    def test_comments_and_strings_do_not_count_as_imports(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "main_sema.l").write_text("// import bogus\nlet s = \"import nope\"\n", encoding="utf-8")
            report = module.audit(root)
            self.assertTrue(report.valid)
            self.assertEqual(report.dependencies["main_sema.l"], [])

    def test_duplicate_import_notice(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "main_sema.l").write_text("import a\nimport a\n", encoding="utf-8")
            (root / "a.l").write_text("", encoding="utf-8")
            report = module.audit(root)
            self.assertTrue(report.valid)
            self.assertEqual(len(report.duplicate_imports), 1)
            self.assertEqual(report.dependencies["main_sema.l"], ["a.l"])


if __name__ == "__main__":
    unittest.main()
