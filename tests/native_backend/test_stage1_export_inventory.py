"""Diagnostic inventory of Stage 1's cross-module helper calls.

This test is intentionally observational: a name-based static scan can suggest
missing exports, but it cannot replace Stage 0/Stage 1's semantic resolver.
Review results before editing visibility.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2] / "compiler-l" / "src"
DECL = re.compile(
    r"(?m)^\s*(?:(?P<visibility>pub|expose)\s+)?"
    r"(?:fn|flow)\s+(?P<name>[A-Za-z_][A-Za-z_0-9]*)\b"
)
IMPORT = re.compile(r"(?m)^\s*(?:import|take)\s+([A-Za-z_][A-Za-z_0-9]*)\b")


def strip_line_comments(source: str) -> str:
    # Remove full-line comments only. This is a conservative heuristic, not a lexer.
    return "\n".join(
        "" if line.lstrip().startswith("//") else line
        for line in source.splitlines()
    )


def missing_export_candidates() -> list[tuple[str, str, str]]:
    sources = {
        path.stem: strip_line_comments(path.read_text(encoding="utf-8"))
        for path in sorted(ROOT.glob("*.l"))
    }
    declarations = {
        module: {
            match.group("name"): bool(match.group("visibility"))
            for match in DECL.finditer(source)
        }
        for module, source in sources.items()
    }
    findings: set[tuple[str, str, str]] = set()
    for caller, source in sources.items():
        imports = set(IMPORT.findall(source))
        for dependency in imports:
            if dependency == caller or dependency not in declarations:
                continue
            for name, is_exported in declarations[dependency].items():
                if is_exported:
                    continue
                # A same-named local function takes precedence; do not suggest
                # exporting one from the imported dependency.
                if name in declarations[caller]:
                    continue
                if re.search(r"(?<![.A-Za-z_0-9])" + re.escape(name) + r"\s*\(", source):
                    findings.add((dependency, name, caller))
    return sorted(findings)


class Stage1ExportInventory(unittest.TestCase):
    def test_report_cross_module_private_call_candidates(self) -> None:
        self.assertTrue(ROOT.is_dir(), "Stage 1 source directory missing")
        findings = missing_export_candidates()
        if findings:
            print(f"\nSTAGE1_EXPORT_CANDIDATES count={len(findings)}")
            for module, name, caller in findings:
                print(f"STAGE1_EXPORT_CANDIDATE {module}.l::{name} called_from={caller}.l")
        else:
            print("\nSTAGE1_EXPORT_CANDIDATES count=0")
        # Informational, not a substitute for semantic visibility tests.


if __name__ == "__main__":
    unittest.main()
