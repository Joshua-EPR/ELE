#!/usr/bin/env python3
"""Deterministic, executable native CFG differential: main versus PR.

This intentionally compiles TWO copies of the actual ELE-written backend,
using the SAME Stage 0 executable and identical fixture inputs. It compares
accept/reject decisions, diagnostics, exact ELF64 bytes and safe runtime
outcomes. The Stage 0 binary itself is not a subject of this comparison.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
# These cases are already exercised by the repository's native Rust suites;
# they are intentionally finite and safe to run as ELF64 on Linux.
EXECUTABLE_FIXTURES = {
    "native_cfg_loop_call.lir",
    "native_cfg_branch.lir",
    "native_cfg_nested_copy.lir",
    "native_cfg_enum_positive.lir",
    "native_cfg_enum_payload_int.lir",
    "native_cfg_enum_payload_wrong_active.lir",
    "native_cfg_partial_move_ok.lir",
    "native_cfg_list_index_ok.lir",
    "native_cfg_list_index_oob.lir",
    "native_cfg_list_index_negative.lir",
    "native_cfg_list_reserve_negative.lir",
    "native_cfg_list_elem_ref_ok.lir",
    "native_cfg_list_elem_store_owned.lir",
    "native_cfg_loan_ok.lir",
    "native_cfg_loan_disjoint_fields.lir",
    "native_cfg_text_literal_ok.lir",
    "native_cfg_tfield_replace_ok.lir",
    "native_cfg_ref_store_ok.lir",
}
# These invalid inputs must not become accepted on either side.
REJECT_FIXTURES = {
    "native_cfg_loan_alias_locals.lir",
    "native_cfg_loan_alias_direct.lir",
    "native_cfg_loan_shared_kills_exclusive.lir",
    "native_cfg_loan_after_move.lir",
    "native_cfg_loan_after_push.lir",
    "native_cfg_loan_after_drop.lir",
    "native_cfg_partial_join.lir",
    "native_cfg_partial_return.lir",
    "native_cfg_list_leak.lir",
    "native_cfg_list_use_after_move.lir",
    "native_cfg_list_double_drop.lir",
    "native_cfg_list_elem_move.lir",
    "native_cfg_tfield_double_drop.lir",
    "native_cfg_enum_payload_use_after_move.lir",
}


def call(args: list[str], *, cwd: Path, timeout: int = 180) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        args, cwd=cwd, capture_output=True, timeout=timeout, check=False,
    )


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def normalize(payload: bytes, source_root: Path) -> bytes:
    return (
        payload.replace(str(source_root).encode(), b"<SOURCE_ROOT>")
        .replace(b"\r\n", b"\n")
    )


def executable(name: str, root: Path, build_dir: Path, stage0: Path) -> Path:
    """Build an ELE entry source using Stage 0, just like stage1_support."""
    build_dir.mkdir(parents=True, exist_ok=True)
    source = root / "compiler-l" / "src" / f"{name}.l"
    result = call([str(stage0), "build", str(source)], cwd=build_dir, timeout=360)
    require(
        result.returncode == 0,
        f"{root.name}: cannot bootstrap {name}: {result.stderr.decode(errors='replace')}",
    )
    lines = result.stdout.decode(errors="replace").splitlines()
    name_line = next((line.removeprefix("Build: ").strip() for line in lines if line.startswith("Build: ")), None)
    require(name_line is not None, f"{root.name}: missing Build: output for {name}")
    compiled = build_dir / name_line
    require(compiled.is_file(), f"{root.name}: missing compiled binary {compiled}")
    return compiled.resolve()


def different_bytes(a: bytes, b: bytes) -> str:
    size = min(len(a), len(b))
    at = next((i for i in range(size) if a[i] != b[i]), size)
    return f"first differing byte={at}, lengths={len(a)}/{len(b)}"


def compare_lir(
    base: Path, head: Path, tools: dict[str, Path],
    tmp: Path, rows: list[dict[str, Any]],
) -> tuple[int, int]:
    native_count = 0
    executed_count = 0
    lir = sorted((head / "examples").glob("native_cfg_*.lir"))
    require(len(lir) >= 100, f"expected >=100 native CFG LIR fixtures, got {len(lir)}")
    for fixture in lir:
        original = base / "examples" / fixture.name
        require(original.is_file(), f"fixture missing on main: {fixture.name}")
        require(
            original.read_bytes() == fixture.read_bytes(),
            f"fixture changed between main and PR: {fixture.name}",
        )
        results: dict[str, subprocess.CompletedProcess[bytes]] = {}
        binary: dict[str, bytes | None] = {}
        images: dict[str, Path] = {}
        for label, srcroot in (("main", base), ("pr", head)):
            dest = tmp / label / "elf" / (fixture.stem + ".elf")
            dest.parent.mkdir(parents=True, exist_ok=True)
            res = call([str(tools[label]), str(fixture), str(dest)], cwd=tmp, timeout=30)
            results[label] = res
            binary[label] = dest.read_bytes() if dest.is_file() else None
            images[label] = dest
        a, b = results["main"], results["pr"]
        require(a.returncode == b.returncode, f"{fixture.name}: exit {a.returncode} != {b.returncode}")
        for name in ("stdout", "stderr"):
            require(
                normalize(getattr(a, name), base) == normalize(getattr(b, name), head),
                f"{fixture.name}: backend {name} differs between main and PR",
            )
        require(
            (binary["main"] is None) == (binary["pr"] is None),
            f"{fixture.name}: one backend emitted ELF64 and the other did not",
        )
        if fixture.name in REJECT_FIXTURES:
            require(a.returncode != 0, f"{fixture.name}: formerly rejected unsafe LIR was accepted")
        row: dict[str, Any] = {
            "fixture": fixture.name, "exit": a.returncode,
            "stderr_sha256": digest(normalize(a.stderr, base)),
        }
        if a.returncode == 0:
            require(binary["main"] is not None, f"{fixture.name}: successful compile produced no ELF")
            old_image, new_image = binary["main"], binary["pr"]
            assert old_image is not None and new_image is not None
            require(
                old_image == new_image,
                f"{fixture.name}: emitted ELF64 differs: {different_bytes(old_image, new_image)}; "
                f"sha256={digest(old_image)} vs {digest(new_image)}",
            )
            row["elf_sha256"] = digest(old_image)
            native_count += 1
            if fixture.name in EXECUTABLE_FIXTURES:
                run_results = []
                for label in ("main", "pr"):
                    dest = images[label]
                    dest.chmod(dest.stat().st_mode | 0o111)
                    run_results.append(call([str(dest)], cwd=tmp, timeout=15))
                first, second = run_results
                require(
                    (first.returncode, first.stdout, first.stderr)
                    == (second.returncode, second.stdout, second.stderr),
                    f"{fixture.name}: native runtime behavior diverged between main and PR",
                )
                row["runtime_exit"] = first.returncode
                row["stdout_sha256"] = digest(first.stdout)
                row["runtime_stderr_sha256"] = digest(first.stderr)
                executed_count += 1
        rows.append(row)
        print(f"LIR {fixture.name}: compile {a.returncode}, " + (
            f"ELF sha256={row['elf_sha256'][:16]}" if "elf_sha256" in row else "rejected identically"
        ), flush=True)
    missing = EXECUTABLE_FIXTURES - {r["fixture"] for r in rows}
    require(not missing, f"missing safe runtime fixtures: {sorted(missing)}")
    missing = REJECT_FIXTURES - {r["fixture"] for r in rows}
    require(not missing, f"missing negative fixtures: {sorted(missing)}")
    return native_count, executed_count


def compare_stage1(
    base: Path, head: Path, sema: dict[str, Path],
    tmp: Path, rows: list[dict[str, Any]],
) -> int:
    examples = sorted((head / "examples").rglob("*.l"))
    require(len(examples) >= 40, f"expected >=40 ELE sources, got {len(examples)}")
    for source in examples:
        relative = source.relative_to(head)
        original = base / relative
        require(original.is_file(), f"source missing in main: {relative}")
        require(original.read_bytes() == source.read_bytes(), f"source changed: {relative}")
        row: dict[str, Any] = {"source": str(relative)}
        for option in ("--emit-lir", "--check-ownership"):
            results = []
            for label in ("main", "pr"):
                result = call([str(sema[label]), str(source), option], cwd=tmp, timeout=30)
                results.append(result)
            a, b = results
            require(
                a.returncode == b.returncode,
                f"{relative}: {option}: Stage 1 exit {a.returncode} != {b.returncode}",
            )
            require(
                normalize(a.stdout, base) == normalize(b.stdout, head),
                f"{relative}: {option}: Stage 1 stdout differs",
            )
            require(
                normalize(a.stderr, base) == normalize(b.stderr, head),
                f"{relative}: {option}: Stage 1 diagnostic differs\\n"
                f"main: {a.stderr[:2400]!r}\\npr: {b.stderr[:2400]!r}",
            )
            row[option] = {
                "exit": a.returncode,
                "stdout_sha256": digest(normalize(a.stdout, base)),
                "stderr_sha256": digest(normalize(a.stderr, base)),
            }
        rows.append(row)
        print(f"Stage1 {relative}: same LIR and ownership diagnostics", flush=True)
    return len(rows)


def main() -> int:
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--base", required=True, help="Pinned PR base commit SHA")
    options = args.parse_args()
    require(bool(re.fullmatch(r"[0-9a-fA-F]{40}", options.base)), "base must be an exact Git SHA")
    require(sys.platform == "linux", "differential ELF execution requires Linux x86-64")
    stage0 = (ROOT / "target" / "debug" / "l").resolve()
    require(stage0.is_file(), f"missing Stage 0 binary {stage0}; run cargo build -p project-l --bin l")

    # Results are always written in PR target/, even if a comparison fails.
    report = ROOT / "target" / "differential" / "native-cfg-results.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    summary: dict[str, Any] = {
        "base_sha": options.base,
        "pr_checkout": call(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.decode().strip(),
        "status": "running", "lir": [], "stage1": [],
    }
    with tempfile.TemporaryDirectory(prefix="ele-native-diff-", dir=os.getenv("RUNNER_TEMP")) as work:
        workdir = Path(work)
        baseline = workdir / "baseline"
        obtained = call(["git", "worktree", "add", "--detach", str(baseline), options.base], cwd=ROOT)
        require(obtained.returncode == 0, f"cannot check out base: {obtained.stderr!r}")
        try:
            tools = {
                label: executable("native_cfg_demo", srcroot, workdir / label / "build-backend", stage0)
                for label, srcroot in (("main", baseline), ("pr", ROOT))
            }
            sema = {
                label: executable("main_sema", srcroot, workdir / label / "build-sema", stage0)
                for label, srcroot in (("main", baseline), ("pr", ROOT))
            }
            compiled, executed = compare_lir(baseline, ROOT, tools, workdir, summary["lir"])
            sources = compare_stage1(baseline, ROOT, sema, workdir, summary["stage1"])
            summary.update({
                "status": "pass", "lir_fixtures": len(summary["lir"]),
                "native_elf_identical": compiled, "native_elf_executed": executed,
                "stage1_sources": sources,
            })
            print(
                f"PASS: {len(summary['lir'])} LIR cases; {compiled} byte-identical ELF64; "
                f"{executed} identical ELF runtime outcomes; {sources} sources with "
                "matching Stage 1 LIR and ownership diagnostics.",
                flush=True,
            )
        except (AssertionError, subprocess.TimeoutExpired) as exc:
            summary["status"] = "fail"
            summary["failure"] = str(exc)
            raise
        finally:
            report.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            call(["git", "worktree", "remove", "--force", str(baseline)], cwd=ROOT)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, subprocess.TimeoutExpired) as exc:
        print(f"DIFFERENTIAL FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
