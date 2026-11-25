from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP_WORKFLOW = ROOT / ".github/workflows/stage0-free-bootstrap.yml"
LEGACY_WORKFLOW = ROOT / ".github/workflows/native-selfhosting-validation.yml"


def workflow_job(name: str, next_name: str | None = None) -> str:
    text = BOOTSTRAP_WORKFLOW.read_text(encoding="utf-8")
    start = text.index(f"  {name}:")
    if next_name is None:
        return text[start:]
    end = text.index(f"  {next_name}:", start + 1)
    return text[start:end]


class Gen3SelfCoverageWorkflowTests(unittest.TestCase):
    def test_linux_job_gates_self_coverage_with_gen3_elf_after_corpus(self):
        job = workflow_job("bootstrap-linux", "bootstrap-windows")
        self.assertIn("python3; do", job)
        self.assertLess(
            job.index("Restrict PATH to runtime utilities"),
            job.index("Gen3 self-coverage gate"),
        )
        self.assertLess(
            job.index("Native conformance corpus with Gen3"),
            job.index("Gen3 self-coverage gate"),
        )
        self.assertIn("for tool in cargo rustc rustup l cl link", job)
        self.assertIn("--gen3 \"${{ runner.temp }}/bootstrap-elf/gen3.elf\"", job)
        self.assertIn("--gen3-target elf", job)
        self.assertIn("--baseline docs/SELF_COVERAGE_MATRIX_2026-11-11.md", job)

    def test_windows_job_gates_self_coverage_with_gen3_pe_after_corpus(self):
        job = workflow_job("bootstrap-windows")
        self.assertIn("$python = Get-Command python", job)
        self.assertIn("(Split-Path -Parent $python.Source)", job)
        self.assertLess(
            job.index("Restrict PATH to Windows runtime utilities"),
            job.index("Gen3 self-coverage gate"),
        )
        self.assertLess(
            job.index("Native conformance corpus with Gen3"),
            job.index("Gen3 self-coverage gate"),
        )
        self.assertIn("foreach ($t in 'cargo', 'rustc', 'rustup', 'l', 'cl'", job)
        self.assertIn("bootstrap-pe/gen3.exe", job)
        self.assertIn("--gen3-target pe", job)
        self.assertIn("--baseline docs/SELF_COVERAGE_MATRIX_2026-11-11.md", job)

    def test_historical_stage0_self_coverage_and_regression_suite_remain(self):
        text = LEGACY_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("cargo test -p project-l", text)
        self.assertIn("Test self-coverage gate (MSVC)", text)
        self.assertIn("python tools/self_coverage_gate.py", text)


if __name__ == "__main__":
    unittest.main()
