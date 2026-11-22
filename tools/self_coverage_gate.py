#!/usr/bin/env python3
"""Reproducible Stage 1 self-coverage report and monotonic regression gate.

This is a DEVELOPMENT-ONLY harness. It runs the ELE-written Stage 1 binaries;
it does not implement ELE parsing, semantics, LIR, or module visibility.
Each source is an entry point whose transitive imports are loaded by Stage 1.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

from ele_source_audit import audit as source_graph_audit

ROOT = Path(__file__).resolve().parents[1]
PHASES = ("parser", "ownership", "lir", "native")
DIAGNOSTIC = re.compile(
    r"^(?P<path>.+):(?P<line>\d+):(?P<column>\d+):\s*"
    r"error\[(?P<code>[^]]+)\]:\s*(?P<message>.*)$"
)
CODE = re.compile(r"error\[([^]]+)\]")

# The Stage 1 protocol describes the entry point and table counts on line 2.
# This is advisory diagnosis only; the native backend remains authoritative.
MODULE_HEADER = re.compile(
    r"^module structs (?P<structs>-?\d+)"
    r"(?: enums (?P<enums>-?\d+))?"
    r"(?: lists (?P<lists>-?\d+))?"
    r" funcs (?P<funcs>-?\d+) main f(?P<main>-?\d+)$"
)


def inspect_module_header(lir: str) -> dict[str, int] | None:
    lines = lir.splitlines()
    if len(lines) < 2 or lines[0] != "ELE-LIR 1":
        return None
    match = MODULE_HEADER.fullmatch(lines[1])
    if not match:
        return None
    return {key: int(value) if value is not None else 0
            for key, value in match.groupdict().items()}


def code48_hint(module: dict[str, int] | None, code: int | None) -> str | None:
    """Expose guard predicates, not a claimed native parser root cause."""
    if code != 48:
        return None
    if module is None:
        return "backend 48; LIR header unavailable or malformed"
    if module["main"] < 0 or module["main"] >= module["funcs"]:
        return "entrypoint missing or out of range (backend guard includes main)"
    if (module["structs"] > 16 or module["enums"] > 16 or
            module["lists"] > 64 or module["funcs"] < 1 or
            module["funcs"] > 256):
        return "module counts exceed current native backend guard"
    return "backend 48; inspect parser errors and remaining header invariants"




def find_binary(target: Path, name: str, sources: Path) -> Path:
    # Every test process builds its Stage 1 tools in a directory of its own
    # (tests/stage1_support), so one run leaves several copies. Measure the
    # newest, and never one that predates the sources being measured.
    found = list((target / name / "normal").rglob(name + ".exe"))
    if not found:
        raise ValueError(f"no {name}.exe under {target}")
    newest = max(found, key=lambda path: (path.stat().st_mtime_ns, str(path)))
    edited = max((path.stat().st_mtime_ns for path in sources.rglob("*.l")), default=0)
    if newest.stat().st_mtime_ns < edited:
        raise ValueError(f"stale {name}.exe under {target}: rebuild Stage 1 first")
    return newest


def command(argv: list[str], cwd: Path, timeout: int) -> dict[str, Any]:
    try:
        result = subprocess.run(
            argv, cwd=cwd, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout, check=False,
        )
        return {
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
    except subprocess.TimeoutExpired:
        return {"exit_code": None, "stdout": "", "stderr": f"timeout after {timeout}s"}
    except OSError as error:
        return {"exit_code": None, "stdout": "", "stderr": f"process error: {error}"}


def error_details(text: str) -> dict[str, Any]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    first = next((line for line in lines if "error[" in line), lines[0] if lines else "")
    match = DIAGNOSTIC.match(first)
    if match:
        return {
            "code": match.group("code"),
            "message": match.group("message")[:2000],
            "span": {
                "path": match.group("path"),
                "line": int(match.group("line")),
                "column": int(match.group("column")),
            },
        }
    code = CODE.search(first)
    return {"code": code.group(1) if code else None, "message": first[:2000], "span": None}


def phase_result(run: dict[str, Any], *, reason: str = "") -> dict[str, Any]:
    ok = run["exit_code"] == 0 and not reason
    details = error_details(reason or run["stderr"]) if not ok else {
        "code": None, "message": "", "span": None,
    }
    return {
        "status": "pass" if ok else "fail",
        "exit_code": run["exit_code"],
        **details,
    }


def skipped() -> dict[str, Any]:
    return {
        "status": "skipped", "exit_code": None, "code": None,
        "message": "previous phase failed", "span": None,
    }


def probe_source(
    source: Path, relative: str, parser: Path, sema: Path,
    native: Path, out_dir: Path, root: Path, timeout: int,
) -> dict[str, Any]:
    phases: dict[str, dict[str, Any]] = {}
    parsed = command([str(parser), str(source)], root, timeout)
    phases["parser"] = phase_result(parsed)
    if phases["parser"]["status"] != "pass":
        return {"source": relative, "phases": {**phases, **{p: skipped() for p in PHASES[1:]}}}

    owned = command([str(sema), str(source), "--check-ownership"], root, timeout)
    phases["ownership"] = phase_result(owned)
    if phases["ownership"]["status"] != "pass":
        return {"source": relative, "phases": {**phases, "lir": skipped(), "native": skipped()}}

    emitted = command([str(sema), str(source), "--emit-lir"], root, timeout)
    lir_reason = ""
    if emitted["exit_code"] == 0 and not emitted["stdout"].startswith("ELE-LIR 1\n"):
        lir_reason = "error[AUDIT-LIR]: successful emitter returned no ELE-LIR 1 header"
    phases["lir"] = phase_result(emitted, reason=lir_reason)
    if phases["lir"]["status"] != "pass":
        return {"source": relative, "phases": {**phases, "native": skipped()}}

    # Preserve directory structure: a/b.l and a_b.l must never collide.
    lir = out_dir / "generated" / Path(relative).with_suffix(".lir")
    image = out_dir / "generated" / Path(relative).with_suffix(".elf")
    lir.parent.mkdir(parents=True, exist_ok=True)
    lir.write_text(emitted["stdout"], encoding="utf-8", newline="\n")
    image.unlink(missing_ok=True)  # Prevent a stale ELF from masking a backend failure.
    built = command([str(native), str(lir), str(image)], root, timeout)
    reason = ""
    if built["exit_code"] == 0:
        if not image.is_file() or image.read_bytes()[:4] != b"\x7fELF":
            reason = "error[AUDIT-ELF]: backend returned success without an ELF64 image"
    phases["native"] = phase_result(built, reason=reason)
    info = inspect_module_header(emitted["stdout"])
    return {
        "source": relative,
        "phases": phases,
        "lir_module": info,
        # Stage 0 wrappers may translate an ELE native reject (48) into
        # a host process exit (3), retaining the original diagnostic.
        # Derive only an advisory hint; never change the native phase status
        # or its actual exit code.
        "native_48_hint": code48_hint(
            info,
            48
            if built["exit_code"] == 48
            or (
                built["exit_code"] not in (None, 0)
                and "ELE-LIR/CFG rechazado (código 48)" in built["stderr"]
            )
            else built["exit_code"],
        ),
    }


def load_baseline(path: Path) -> dict[str, dict[str, bool]]:
    """Only formerly green phases are locked; historical failures may improve."""
    baseline: dict[str, dict[str, bool]] = {}
    if path.suffix.lower() == ".json":
        data = json.loads(path.read_text(encoding="utf-8"))
        for row in data["rows"]:
            baseline[row["source"]] = {
                p: row["phases"][p]["status"] == "pass" for p in PHASES
            }
    else:
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.startswith("| `"):
                continue
            cells = [part.strip() for part in line.strip().strip("|").split(" | ")]
            if len(cells) != 5:
                raise ValueError(f"invalid baseline table row: {line[:160]}")
            name = cells[0].strip("`")
            baseline[name] = {
                p: cells[index + 1] == "Sí" for index, p in enumerate(PHASES)
            }
    if not baseline:
        raise ValueError(f"baseline has no source rows: {path}")
    return baseline


def regressions(
    rows: list[dict[str, Any]], baseline: dict[str, dict[str, bool]],
) -> list[str]:
    current = {row["source"]: row["phases"] for row in rows}
    errors: list[str] = []
    for source, expected in sorted(baseline.items()):
        if source not in current:
            errors.append(f"{source}: previously measured source is missing")
            continue
        for phase, was_green in expected.items():
            if was_green and current[source][phase]["status"] != "pass":
                details = current[source][phase]
                errors.append(
                    f"{source}: {phase} regressed to {details['status']} "
                    f"({details['code'] or details['message']})"
                )
    return errors


def markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    total = summary["sources"]
    lines = [
        "# Autocobertura Stage 1 — reporte reproducible",
        "",
        "Cada archivo es una entrada independiente; Stage 1 resuelve sus imports.",
        "No representa cobertura por función, ejecución ELF64 ni prueba de Stage 2.",
        "",
        f"Parser: {summary['parser']}/{total}; ownership: {summary['ownership']}/{total}; "
        f"LIR: {summary['lir']}/{total}; ELF64 generado: {summary['native']}/{total}.",
        "",
        "| Fuente | Parser | Ownership | LIR | ELF64 |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in report["rows"]:
        cells = [row["source"]]
        for phase in PHASES:
            result = row["phases"][phase]
            value = result["status"]
            if value == "fail":
                value += ": " + (result["code"] or result["message"] or "unknown")
            cells.append(value.replace("|", "\\|").replace("`", "'"))
        lines.append("| " + " | ".join(cells) + " |")
    lines.extend(["", "Los diagnósticos con ubicación y códigos están en el JSON adjunto.", ""])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT / "compiler-l/src")
    parser.add_argument("--target", type=Path, default=ROOT / "target/stage1-tests")
    parser.add_argument("--output", type=Path, default=ROOT / "target/stage1-tests/self-coverage-gate")
    parser.add_argument("--baseline", type=Path, help="existing JSON or Markdown matrix; fail on formerly green regressions")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args(argv)
    try:
        if args.timeout < 1:
            raise ValueError("timeout must be positive")
        root = args.source_root.resolve(strict=True)
        source_paths = sorted(root.rglob("*.l"))
        if not source_paths:
            raise ValueError(f"no ELE sources in {root}")
        paths = {name: find_binary(args.target, name, root) for name in
                 ("main_parser", "main_sema", "native_cfg_demo")}
        args.output.mkdir(parents=True, exist_ok=True)
        rows = [
            probe_source(source, source.relative_to(root).as_posix(),
                         paths["main_parser"], paths["main_sema"],
                         paths["native_cfg_demo"], args.output, ROOT, args.timeout)
            for source in source_paths
        ]
        graph = source_graph_audit(root, "main_sema.l")
        summary = {
            "sources": len(rows),
            **{phase: sum(row["phases"][phase]["status"] == "pass" for row in rows)
               for phase in PHASES},
        }
        report: dict[str, Any] = {
            "schema_version": 1,
            "measurement": "per-source entry + transitive imports; sequential pipeline",
            "summary": summary,
            "graph": {
                "entry": graph.entry,
                "reachable": graph.reachable,
                "missing": graph.missing,
                "cycles": graph.cycles,
                "valid": graph.valid,
                "warning": "static source inventory, not semantic proof",
            },
            "rows": rows,
        }
        failures = regressions(rows, load_baseline(args.baseline)) if args.baseline else []
        report["regressions"] = failures
        (args.output / "report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        (args.output / "report.md").write_text(markdown(report), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False))
        for item in failures:
            print("REGRESSION: " + item, file=sys.stderr)
        print(f"Artifacts: {args.output / 'report.json'}")
        return 1 if failures else 0
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"self-coverage harness failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
