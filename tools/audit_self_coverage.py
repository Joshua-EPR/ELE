#!/usr/bin/env python3
"""Measure each real Stage 1 source through the current compiler pipeline."""
from __future__ import annotations

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "compiler-l" / "src"
TARGET = ROOT / "target" / "stage1-tests"
OUT = ROOT / "docs" / "SELF_COVERAGE_MATRIX_2026-11-11.md"


def binary(name: str) -> Path:
    matches = list((TARGET / name / "normal").rglob(name + ".exe"))
    if len(matches) != 1:
        raise RuntimeError(f"expected one {name}.exe, found {matches}")
    return matches[0]


def run(exe: Path, *args: Path | str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(exe), *(str(arg) for arg in args)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
        check=False,
    )


def result(out: subprocess.CompletedProcess[str]) -> str:
    if out.returncode == 0:
        return "Sí"
    lines = [line.strip() for line in out.stderr.splitlines() if line.strip()]
    detail = lines[0] if lines else f"salida {out.returncode} sin diagnóstico"
    return f"No ({detail})".replace("|", "\\|").replace("`", "'")


def main() -> None:
    parser = binary("main_parser")
    sema = binary("main_sema")
    native = binary("native_cfg_demo")
    audit_dir = TARGET / "self-coverage-audit"
    audit_dir.mkdir(exist_ok=True)
    rows = []
    for source in sorted(SRC.rglob("*.l")):
        label = source.relative_to(SRC).as_posix()
        parsed = run(parser, source)
        checked = run(sema, source, "--check-ownership") if parsed.returncode == 0 else None
        emitted = run(sema, source, "--emit-lir") if checked and checked.returncode == 0 else None
        verified = None
        if emitted and emitted.returncode == 0:
            lir = audit_dir / (label.replace("/", "_") + ".lir")
            image = audit_dir / (label.replace("/", "_") + ".elf")
            lir.write_text(emitted.stdout, encoding="utf-8", newline="\n")
            verified = run(native, lir, image)
        rows.append(
            (label, result(parsed), result(checked) if checked else "No ejecutado",
             result(emitted) if emitted else "No ejecutado",
             result(verified) if verified else "No ejecutado")
        )

    passed = [sum(row[column] == "Sí" for row in rows) for column in range(1, 5)]
    lines = [
        "# Autocobertura de `compiler-l/src` — medición 2026-11-11",
        "",
        f"Resultado: {passed[0]}/{len(rows)} pasan parser, {passed[1]}/{len(rows)} semántica y ownership,",
        f"{passed[2]}/{len(rows)} emiten LIR verificada y {passed[3]}/{len(rows)} pasa el backend ELE.",
        "Estas fracciones corresponden a entradas independientes y son",
        "recuentos de archivos, no porcentajes de funcionalidad cubierta.",
        "",
        "Cada fila corresponde a una fuente `.l` real invocada como entrada",
        "independiente. Parser: `main_parser.exe archivo`; semántica y ownership:",
        "`main_sema.exe archivo --check-ownership`; LIR y su verificador:",
        "`main_sema.exe archivo --emit-lir`; backend ELE: `native_cfg_demo.exe`",
        "sobre el LIR emitido. Las fases posteriores se ejecutan solo cuando la",
        "anterior pasa. Un archivo de biblioteca sin `main` puede fallar como",
        "entrada independiente aunque sus funciones sean válidas al importarlo.",
        "La compilación nativa solo acredita que se produjo un ELF64 en Windows;",
        "esta matriz no demuestra su ejecución en Linux ni Stage 2/3.",
        "",
        "| Fuente | Parser | Semántica y ownership | LIR y verificador | Backend ELE / ELF64 |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(f"`{cell}`" if i == 0 else cell for i, cell in enumerate(row)) + " |")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"Audited {len(rows)} sources -> {OUT}")


if __name__ == "__main__":
    main()
