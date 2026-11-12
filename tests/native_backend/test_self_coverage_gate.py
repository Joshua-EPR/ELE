"""Unit tests for the Stage 1 coverage harness (no compiler binary required)."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[2] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("self_coverage_gate", TOOLS / "self_coverage_gate.py")
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class SelfCoverageGateTests(unittest.TestCase):
    def test_parse_windows_diagnostic_preserves_original_span(self):
        d = gate.error_details(
            r"C:\repo\compiler-l\src\tokens.l:28:42: error[L0001]: tipo desconocido"
        )
        self.assertEqual(d["code"], "L0001")
        self.assertEqual(d["span"]["path"], r"C:\repo\compiler-l\src\tokens.l")
        self.assertEqual((d["span"]["line"], d["span"]["column"]), (28, 42))

    def test_skip_pipeline_after_ownership_failure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "some.l"
            source.write_text("flow main() {}", encoding="utf-8")
            calls = []

            def fake_command(argv, cwd, timeout):
                calls.append(argv)
                if len(argv) == 2:
                    return {"exit_code": 0, "stdout": "AST", "stderr": ""}
                return {"exit_code": 1, "stdout": "", "stderr": "error[L0012]: borrow"}

            with patch.object(gate, "command", side_effect=fake_command):
                row = gate.probe_source(source, "some.l", Path("parser"),
                                        Path("sema"), Path("backend"), root, root, 10)
            self.assertEqual(len(calls), 2)
            self.assertEqual(row["phases"]["ownership"]["code"], "L0012")
            self.assertEqual(row["phases"]["lir"]["status"], "skipped")
            self.assertEqual(row["phases"]["native"]["status"], "skipped")

    def test_lir_success_without_version_header_must_fail(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "some.l"
            source.write_text("", encoding="utf-8")

            def fake_command(argv, cwd, timeout):
                return {"exit_code": 0, "stdout": "not LIR", "stderr": ""}

            with patch.object(gate, "command", side_effect=fake_command):
                row = gate.probe_source(source, "some.l", Path("parser"),
                                        Path("sema"), Path("backend"), root, root, 10)
            self.assertEqual(row["phases"]["lir"]["status"], "fail")
            self.assertEqual(row["phases"]["lir"]["code"], "AUDIT-LIR")

    def test_backend_success_without_image_must_not_count(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "x.l"
            source.write_text("", encoding="utf-8")
            image = root / "generated" / "x.elf"
            image.parent.mkdir(parents=True)
            image.write_bytes(b"\x7fELF\x02stale")

            def fake_command(argv, cwd, timeout):
                return {"exit_code": 0, "stdout": "ELE-LIR 1\nend\n", "stderr": ""}

            with patch.object(gate, "command", side_effect=fake_command):
                row = gate.probe_source(source, "x.l", Path("parser"),
                                        Path("sema"), Path("backend"), root, root, 10)
            self.assertFalse(image.exists(), "old image was not removed")
            self.assertEqual(row["phases"]["native"]["code"], "AUDIT-ELF")

    def test_distinct_source_paths_have_distinct_lir_files(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a").mkdir()
            files = [root / "a" / "b.l", root / "a_b.l"]
            for f in files:
                f.write_text("", encoding="utf-8")

            def fake_command(argv, cwd, timeout):
                if str(argv[0]) == "backend":
                    Path(argv[2]).write_bytes(b"\x7fELF\x02test")
                    return {"exit_code": 0, "stdout": "", "stderr": ""}
                return {"exit_code": 0, "stdout": "ELE-LIR 1\nend\n", "stderr": ""}

            with patch.object(gate, "command", side_effect=fake_command):
                for f in files:
                    rel = f.relative_to(root).as_posix()
                    row = gate.probe_source(f, rel, Path("parser"), Path("sema"),
                                            Path("backend"), root, root, 10)
                    self.assertEqual(row["phases"]["native"]["status"], "pass")
            self.assertTrue((root / "generated/a/b.lir").exists())
            self.assertTrue((root / "generated/a_b.lir").exists())

    def test_legacy_baseline_locks_only_green_phases(self):
        with tempfile.TemporaryDirectory() as td:
            baseline = Path(td) / "baseline.md"
            baseline.write_text(
                "| Fuente | Parser | Semántica | LIR | Backend |\n"
                "| --- | --- | --- | --- | --- |\n"
                "| `ast.l` | Sí | Sí | No (L0016) | No ejecutado |\n",
                encoding="utf-8",
            )
            expected = gate.load_baseline(baseline)
            self.assertEqual(expected["ast.l"], {
                "parser": True, "ownership": True, "lir": False, "native": False,
            })
            rows = [{
                "source": "ast.l",
                "phases": {
                    "parser": {"status": "pass", "code": None, "message": ""},
                    "ownership": {"status": "fail", "code": "L0012", "message": "loan"},
                    "lir": {"status": "skipped", "code": None, "message": ""},
                    "native": {"status": "skipped", "code": None, "message": ""},
                },
            }]
            errors = gate.regressions(rows, expected)
            self.assertEqual(len(errors), 1)
            self.assertIn("ownership", errors[0])

    def test_deleted_source_cannot_silently_pass_baseline(self):
        errors = gate.regressions([], {"missing.l": {"parser": True}})
        self.assertIn("missing.l", errors[0])


    def test_native_module_header_and_code48_invariants(self):
        missing = gate.inspect_module_header(
            "ELE-LIR 1\nmodule structs 2 funcs 3 main f-1\nend\n"
        )
        self.assertEqual(
            missing, {"structs": 2, "enums": 0, "lists": 0, "funcs": 3, "main": -1}
        )
        self.assertIn("entrypoint", gate.code48_hint(missing, 48))
        large = gate.inspect_module_header(
            "ELE-LIR 1\nmodule structs 17 enums 1 lists 1 funcs 1 main f0\n"
        )
        self.assertIn("counts", gate.code48_hint(large, 48))
        self.assertIsNone(gate.code48_hint(large, 1))
        self.assertIsNone(gate.inspect_module_header("garbage"))

    def test_native_code48_diagnosis_does_not_count_as_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "library.l"
            source.write_text("pub fn f() -> Int { return 1 }\n", encoding="utf-8")

            def fake_command(argv, cwd, timeout):
                if str(argv[0]) == "backend":
                    return {"exit_code": 48, "stdout": "", "stderr": "native reject"}
                if "--emit-lir" in argv:
                    return {
                        "exit_code": 0,
                        "stdout": "ELE-LIR 1\nmodule structs 0 funcs 1 main f-1\nend\n",
                        "stderr": "",
                    }
                return {"exit_code": 0, "stdout": "", "stderr": ""}

            with patch.object(gate, "command", side_effect=fake_command):
                row = gate.probe_source(
                    source, "library.l", Path("parser"), Path("sema"),
                    Path("backend"), root, root, 10,
                )
            self.assertEqual(row["phases"]["native"]["status"], "fail")
            self.assertEqual(row["phases"]["native"]["exit_code"], 48)
            self.assertEqual(row["lir_module"]["main"], -1)
            self.assertIn("entrypoint", row["native_48_hint"])


if __name__ == "__main__":
    unittest.main()
