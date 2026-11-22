"""Prevent README performance claims from drifting away from recorded data."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "benchmarks" / "results"
LABELS = {
    "compilation_hello": "`hello.l`",
    "compilation_arithmetic": "`arithmetic.l`",
    "compilation_fibonacci": "`fibonacci.l`",
    "compilation_text_processing": "`text_processing.l`",
    "compilation_multimodule": "`multimodule (main.l)`",
    "compilation_main_sema": "`main_sema.l`",
    "compilation_main_driver": "`main_driver.l`",
}


class BenchmarkReadmeConsistency(unittest.TestCase):
    def test_compilation_tables_are_recorded_measurements(self):
        records = json.loads((DATA / "compilation_benchmarks_windows.json").read_text("utf-8"))
        summary = json.loads((DATA / "summary.json").read_text("utf-8"))
        for file in ("README.md", "README.es.md"):
            text = (ROOT / file).read_text("utf-8")
            self.assertIn(summary["git_sha"], text, file)
            for record in records:
                label = LABELS[record["benchmark_id"]]
                if record["benchmark_id"] == "compilation_main_sema":
                    label += " (Compiler)" if file == "README.md" else " (Compilador)"
                elif record["benchmark_id"] == "compilation_main_driver":
                    label += " (Self-Host)"
                milliseconds = record["median_compile_ms"]
                formatted = (
                    f"{milliseconds / 1000:.2f} s" if milliseconds >= 1000
                    else f"{milliseconds:.2f} ms"
                )
                self.assertIn(
                    f"| {label} | {record['source_lines']} | **{formatted}** | "
                    f"{record['peak_rss_mib']:.2f} MiB | {record['binary_size_bytes']:,} B |",
                    text, f"{file}: {label}",
                )

    def test_external_comparison_tables_match_source(self):
        records = json.loads((DATA / "external_comparison_windows.json").read_text("utf-8"))
        for file in ("README.md", "README.es.md"):
            text = (ROOT / file).read_text("utf-8")
            for record in records:
                workload = "Fibonacci(25)" if "fibonacci" in record["benchmark_id"] else "Loop(10M)"
                lang = "**ELE**" if record["language"] == "ELE" else record["language"]
                needle = (
                    f"| {lang} | "
                    + ("`native-direct-emit`" if lang == "**ELE**" else (
                        "Release (`-O3`)" if record["benchmark_id"].endswith("opt")
                        else "Debug (`-O0`)"
                    ))
                    + f" | {record['median_compile_ms']:.2f} ms "
                      f"| {record['median_runtime_ms']:.2f} ms | {record['binary_size_bytes']:,} B |"
                )
                self.assertIn(needle, text, f"{file}: {workload} {lang}")


if __name__ == "__main__":
    unittest.main()
