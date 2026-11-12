"""Behavioral tests for the native CFG base-vs-PR differential harness.

Unlike text-only source contracts, these ensure the comparison preserves real
changes to ownership diagnostics while ignoring ONLY irrelevant checkout roots.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "tools" / "verify_native_cfg_migration.py"
spec = importlib.util.spec_from_file_location("ele_native_cfg_differential", HARNESS)
assert spec is not None and spec.loader is not None
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class NativeCfgDifferentialContract(unittest.TestCase):
    def test_identical_diagnostics_remain_identical_across_worktree_roots(self):
        baseline = Path("/tmp/ele-cfg-baseline-123456")
        diagnostic = (
            str(ROOT).encode()
            + b"/examples/constants.l:1:24: error[L0016]: unsupported expression\n"
        )
        # Both compilers can analyze an input under the PR root even if the
        # baseline compiler's own source was loaded from a different worktree.
        self.assertEqual(
            harness.normalize(diagnostic, baseline),
            harness.normalize(diagnostic, ROOT),
        )
        # Also handle a true baseline input path symmetrically.
        baseline_diagnostic = diagnostic.replace(
            str(ROOT).encode(), str(baseline).encode()
        )
        self.assertEqual(
            harness.normalize(baseline_diagnostic, baseline),
            harness.normalize(diagnostic, ROOT),
        )

    def test_real_ownership_diagnostic_changes_are_not_normalized_away(self):
        baseline = Path("/tmp/ele-cfg-baseline-123456")
        prefix = str(ROOT).encode() + b"/examples/borrow.l:"
        valid = prefix + "7:4: error[L0012]: préstamo incompatible\n".encode("utf-8")
        changed_code = prefix + "7:4: error[L0013]: préstamo incompatible\n".encode("utf-8")
        changed_location = prefix + "8:4: error[L0012]: préstamo incompatible\n".encode("utf-8")
        changed_message = prefix + "7:4: error[L0012]: préstamo inválido\n".encode("utf-8")
        for mutated in (changed_code, changed_location, changed_message):
            with self.subTest(mutated=mutated):
                self.assertNotEqual(
                    harness.normalize(valid, baseline),
                    harness.normalize(mutated, ROOT),
                )

    def test_only_line_ending_format_is_ignored(self):
        baseline = Path("/tmp/ele-cfg-baseline-123456")
        self.assertEqual(
            harness.normalize(b"error[L0012]\r\n", baseline),
            harness.normalize(b"error[L0012]\n", ROOT),
        )


if __name__ == "__main__":
    unittest.main()
