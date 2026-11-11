#!/usr/bin/env python3
"""Development-only import graph audit for ELE self-hosting.

This checks source-level dependencies only. It is NOT the ELE module resolver,
not a parser, and must never be used to decide semantic symbol visibility.
The final ELE compiler will not depend on this Python tool.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
import sys

IMPORT = re.compile(r"^[ \t]*import[ \t]+([A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*)[ \t]*;?[ \t]*(?://[^\r\n]*)?\r?$", re.MULTILINE)
MAX_SOURCE_BYTES = 16 * 1024 * 1024


@dataclass
class Audit:
    entry: str
    all_sources: int
    reachable: list[str]
    unreachable: list[str]
    dependencies: dict[str, list[str]]
    missing: list[str]
    cycles: list[list[str]]
    duplicate_imports: list[str]

    @property
    def valid(self) -> bool:
        return not self.missing and not self.cycles


def audit(root: Path, entry: str = "main_sema.l") -> Audit:
    root = root.resolve(strict=True)
    names = sorted(str(p.relative_to(root)).replace("\\", "/") for p in root.rglob("*.l"))
    known = set(names)
    deps: dict[str, list[str]] = {}
    missing: list[str] = []
    duplicated: list[str] = []
    for name in names:
        src = root / name
        data = src.read_bytes()
        if len(data) > MAX_SOURCE_BYTES:
            missing.append(f"{name}: file exceeds 16 MiB limit")
            deps[name] = []
            continue
        text = data.decode("utf-8-sig", "strict")
        children = []
        seen = set()
        for m in IMPORT.finditer(text):
            mod = m.group(1)
            if mod == "std.io.print":
                continue
            dep = str((Path(name).parent / (mod.replace(".", "/") + ".l"))).replace("\\", "/")
            if dep not in known:
                missing.append(f"{name} imports missing {dep}")
                continue
            if dep in seen:
                duplicated.append(f"{name} imports {dep} multiple times")
                continue
            seen.add(dep)
            children.append(dep)
        deps[name] = children
    order: list[str] = []
    states: dict[str, int] = {}
    stack: list[str] = []
    cycles: list[list[str]] = []

    def visit(name: str) -> None:
        if states.get(name) == 2:
            return
        if states.get(name) == 1:
            cycles.append(stack[stack.index(name):] + [name])
            return
        if name not in known:
            missing.append(f"entry file does not exist: {name}")
            return
        states[name] = 1
        stack.append(name)
        for child in deps[name]:
            visit(child)
        stack.pop()
        states[name] = 2
        order.append(name)

    visit(entry)
    return Audit(entry, len(names), order, sorted(known - set(order)), deps, missing, cycles, duplicated)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("compiler-l/src"))
    parser.add_argument("--entry", default="main_sema.l")
    parser.add_argument("--json", type=Path, help="save structured report")
    args = parser.parse_args()
    try:
        result = audit(args.root, args.entry)
    except (OSError, UnicodeError, ValueError) as e:
        print(f"ELE static audit failed: {e}", file=sys.stderr)
        return 2
    summary = {
        "entry": result.entry,
        "total_l_files": result.all_sources,
        "reachable_from_entry": len(result.reachable),
        "unreachable_from_entry": len(result.unreachable),
        "import_edges_reachable": sum(len(result.dependencies[n]) for n in result.reachable),
        "missing": result.missing,
        "cycles": result.cycles,
        "duplicate_imports": result.duplicate_imports,
        "warning": "Source graph only; does not prove parsing, semantics, ownership, LIR or native compilation",
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(asdict(result), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if result.valid else 1


if __name__ == "__main__":
    sys.exit(main())
