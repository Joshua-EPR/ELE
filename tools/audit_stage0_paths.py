#!/usr/bin/env python3
"""Audit active Stage 0/toolchain references in official ELE paths.

This is a migration ratchet, not a claim that the repository is Rust-free.
Every active reference in the scoped build, bootstrap, packaging, configuration
and official documentation paths must be covered by ACTIVE_ALLOWLIST. Files
explicitly marked as migration history are reported separately and do not
count as active route violations.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Mapping


ROOT = Path(__file__).resolve().parents[1]

# Keep this inventory narrow and reviewable. Tests, generated files, editor
# integrations and the Stage 0 implementation itself are not official build
# route descriptors; the workspace manifests and Stage 0 CLI boundary are.
OFFICIAL_GLOBS = (
    ".github/workflows/**/*.yml",
    ".github/workflows/**/*.yaml",
    "scripts/bootstrap/**/*",
    "scripts/package*.py",
    "scripts/install.*",
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    "build-clean.ps1",
    "install.ps1",
    "run_full_trace.ps1",
    "crates/l/Cargo.toml",
    "crates/l/build.rs",
    "crates/l/src/main.rs",
    "compiler-l/src/main_driver.l",
    "README.md",
    "README.es.md",
    "STAGE0_*.md",
    "docs/getting-started.md",
    "docs/self-hosting.md",
    "docs/SELF_HOSTING_ROADMAP.md",
    "docs/RUST_FREE_BACKEND.md",
    "docs/STAGE0_*.md",
)

# These documents are deliberately retained as migration/audit history.
# Keep the exceptions path-based so adding similar language to a live guide
# cannot silently opt that guide out of enforcement.
HISTORICAL_GLOBS = (
    "STAGE0_*.md",
    "docs/STAGE0_*.md",
    "scripts/bootstrap/seeds/README.md",
    "scripts/bootstrap/seeds/manifest.json",
)

TEXT_SUFFIXES = {
    ".cfg", ".ini", ".json", ".l", ".lock", ".md", ".ps1", ".py",
    ".rs", ".sh", ".toml", ".txt", ".xml", ".yaml", ".yml",
}

# The allowlist is the inventory of today's known active transition points.
# Each token requires a path-specific reason. A new file or a new token in a
# file fails --enforce until someone makes and reviews a deliberate update.
ACTIVE_ALLOWLIST: dict[str, dict[str, str]] = {
    ".github/workflows/distribution.yml": {
        "cargo": "The native distribution job explicitly asserts the command is unavailable on PATH.",
        "rustc": "The native distribution job explicitly asserts the command is unavailable on PATH.",
        "stage0": "The workflow audits Stage 0 references and restricts the native packaging PATH.",
    },
    ".github/workflows/native-selfhosting-validation.yml": {
        "cargo": "Stage 0 integration, native regression and lint jobs remain during migration.",
        "rustc": "The Windows/Linux Stage 0 test paths still use the reference backend.",
        "cranelift": "The current Windows Stage 0 path still builds Stage 1 through Cranelift.",
        "stage0": "This workflow is the legacy Stage 0/Stage 1 differential and regression gate.",
        "project-l": "Cargo test/build targets for the retained Stage 0 crate.",
    },
    ".github/workflows/docs-and-benchmarks.yml": {
        "cargo": "Legacy workspace format, lint and syntax-ratchet checks remain in this job.",
        "project-l": "The syntax-ratchet test still targets the retained Stage 0 crate.",
    },
    ".github/workflows/stage0-free-bootstrap.yml": {
        "cargo": "The PATH scrub and negative toolchain assertion guard the Rust-free bootstrap.",
        "rustc": "The PATH scrub and negative toolchain assertion guard the Rust-free bootstrap.",
        "stage0": "Workflow identity and explanatory text describe its Stage 0-free migration role.",
    },
    "Cargo.toml": {
        "project-l": "The workspace still contains the Stage 0 crate while its replacement is completed.",
    },
    "Cargo.lock": {
        "cargo": "The Cargo lockfile is retained for the Stage 0 workspace migration period.",
        "cranelift": "Pinned transitive dependencies of the retained Stage 0 crate.",
        "project-l": "The lockfile still records the retained Stage 0 crate.",
    },
    "rust-toolchain.toml": {
        "rustc": "The Rust toolchain pin remains for Stage 0 development and CI during migration.",
    },
    "crates/l/Cargo.toml": {
        "cranelift": "Stage 0's current native backend dependency, scheduled for removal.",
        "project-l": "The Stage 0 crate manifest, scheduled for removal after parity gates.",
    },
    "crates/l/build.rs": {
        "cargo": "Cargo build-script directives remain part of the Stage 0 crate.",
        "rustc": "Stage 0 currently uses rustc to build its Windows platform object.",
    },
    "crates/l/src/main.rs": {
        "rustc": "The retained Stage 0 CLI still exposes its reference backend.",
        "cranelift": "The retained Stage 0 CLI still exposes its current native backend.",
        "stage0": "The retained Stage 0 CLI documents and runs the current bootstrap role.",
        "project-l": "The Stage 0 crate's own CLI and diagnostics identify the crate name.",
    },
    "scripts/bootstrap/bootstrap_stage2.ps1": {
        "cargo": "The legacy Stage 2 probe still starts from a Cargo-built Stage 0 compiler.",
        "stage0": "This legacy probe remains available while its consumers are migrated.",
    },
    "scripts/bootstrap/ele_seed_bootstrap.ps1": {
        "cargo": "The bootstrap explicitly bans the tool from child processes and PATH.",
        "rustc": "The bootstrap explicitly bans the tool from child processes and PATH.",
        "cranelift": "The bootstrap explicitly bans the legacy backend from child processes.",
        "stage0": "The bootstrap guard documents and forbids executing Stage 0.",
    },
    "scripts/bootstrap/ele_seed_bootstrap.sh": {
        "cargo": "The bootstrap explicitly bans the tool from child processes and PATH.",
        "rustc": "The bootstrap explicitly bans the tool from child processes and PATH.",
        "cranelift": "The bootstrap explicitly bans the legacy backend from child processes.",
        "stage0": "The bootstrap guard documents and forbids executing Stage 0.",
    },
    "build-clean.ps1": {
        "cargo": "The legacy cleanup script documents the workspace target cleanup command.",
    },
    "run_full_trace.ps1": {
        "cranelift": "The legacy compiler tracing helper still selects the Rust backend.",
    },
    "README.md": {
        "cargo": "The developer setup still documents workspace tests and lint commands.",
        "rustc": "The README contains an explicit cross-language benchmark comparison.",
        "cranelift": "The README describes the backend comparison and current implementation.",
        "project-l": "The developer commands still target the Stage 0 crate.",
    },
    "README.es.md": {
        "cargo": "The developer setup still documents workspace tests and lint commands.",
        "rustc": "The README contains an explicit cross-language benchmark comparison.",
        "cranelift": "The README describes the backend comparison and current implementation.",
        "project-l": "The developer commands still target the Stage 0 crate.",
    },
    "docs/getting-started.md": {
        "cargo": "The guide documents remaining developer tests and the explicit no-fallback distribution path.",
        "stage0": "The guide documents remaining development dependencies and native packaging.",
        "cranelift": "The guide contains a Stage 0 output path under its Cranelift directory.",
        "project-l": "The existing developer guide still references the Stage 0 crate.",
    },
    "docs/self-hosting.md": {
        "cargo": "The guide describes the current Cargo bootstrap boundary.",
        "rustc": "The guide describes the current reference backend boundary.",
        "cranelift": "The guide describes the current Stage 0 backend boundary.",
        "stage0": "The guide documents the current migration boundary.",
        "project-l": "The guide identifies the retained Stage 0 crate.",
    },
    "docs/SELF_HOSTING_ROADMAP.md": {
        "cargo": "The roadmap records active Cargo consumers awaiting migration.",
        "rustc": "The roadmap records active reference-backend consumers awaiting migration.",
        "cranelift": "The roadmap records active backend consumers awaiting migration.",
        "stage0": "The roadmap tracks the active Stage 0 removal work.",
        "project-l": "The roadmap identifies the retained Stage 0 crate.",
    },
    "docs/RUST_FREE_BACKEND.md": {
        "cargo": "The document explains the active Rust-free backend transition.",
        "rustc": "The document explains the active Rust-free backend transition.",
        "cranelift": "The document compares the existing backend with the native path.",
        "stage0": "The document describes the current migration boundary.",
        "project-l": "The document identifies the retained Stage 0 crate.",
    },
    "compiler-l/src/main_driver.l": {
        "stage0": "The self-hosted driver retains a compatibility diagnostic during migration.",
    },
}

# Exact counts make the migration ratchet fail if a new occurrence is added
# to a file/token pair that already has an approved reference. Update a count
# only when the existing path-specific rationale still applies.
ACTIVE_REFERENCE_COUNTS: dict[tuple[str, str], int] = {
    (".github/workflows/distribution.yml", "cargo"): 2,
    (".github/workflows/distribution.yml", "rustc"): 2,
    (".github/workflows/distribution.yml", "stage0"): 1,
    (".github/workflows/docs-and-benchmarks.yml", "cargo"): 3,
    (".github/workflows/docs-and-benchmarks.yml", "project-l"): 1,
    (".github/workflows/native-selfhosting-validation.yml", "cargo"): 23,
    (".github/workflows/native-selfhosting-validation.yml", "cranelift"): 10,
    (".github/workflows/native-selfhosting-validation.yml", "project-l"): 21,
    (".github/workflows/native-selfhosting-validation.yml", "stage0"): 13,
    (".github/workflows/stage0-free-bootstrap.yml", "cargo"): 8,
    (".github/workflows/stage0-free-bootstrap.yml", "rustc"): 6,
    (".github/workflows/stage0-free-bootstrap.yml", "stage0"): 6,
    ("Cargo.lock", "cargo"): 1,
    ("Cargo.lock", "cranelift"): 42,
    ("Cargo.lock", "project-l"): 1,
    ("README.es.md", "cargo"): 5,
    ("README.es.md", "project-l"): 1,
    ("README.es.md", "rustc"): 2,
    ("README.md", "cargo"): 4,
    ("README.md", "project-l"): 1,
    ("README.md", "rustc"): 2,
    ("build-clean.ps1", "cargo"): 1,
    ("crates/l/Cargo.toml", "cranelift"): 6,
    ("crates/l/Cargo.toml", "project-l"): 2,
    ("crates/l/build.rs", "cargo"): 2,
    ("crates/l/build.rs", "rustc"): 2,
    ("crates/l/src/main.rs", "cranelift"): 13,
    ("crates/l/src/main.rs", "project-l"): 15,
    ("crates/l/src/main.rs", "rustc"): 14,
    ("docs/RUST_FREE_BACKEND.md", "cargo"): 3,
    ("docs/RUST_FREE_BACKEND.md", "cranelift"): 7,
    ("docs/RUST_FREE_BACKEND.md", "rustc"): 3,
    ("docs/RUST_FREE_BACKEND.md", "stage0"): 3,
    ("docs/SELF_HOSTING_ROADMAP.md", "cargo"): 4,
    ("docs/SELF_HOSTING_ROADMAP.md", "cranelift"): 5,
    ("docs/SELF_HOSTING_ROADMAP.md", "stage0"): 3,
    ("docs/getting-started.md", "cargo"): 4,
    ("docs/getting-started.md", "cranelift"): 1,
    ("docs/getting-started.md", "project-l"): 2,
    ("docs/getting-started.md", "stage0"): 4,
    ("docs/self-hosting.md", "cargo"): 2,
    ("docs/self-hosting.md", "project-l"): 2,
    ("docs/self-hosting.md", "stage0"): 2,
    ("run_full_trace.ps1", "cranelift"): 1,
    ("scripts/bootstrap/ele_seed_bootstrap.ps1", "cargo"): 4,
    ("scripts/bootstrap/ele_seed_bootstrap.ps1", "rustc"): 4,
    ("scripts/bootstrap/ele_seed_bootstrap.ps1", "stage0"): 2,
    ("scripts/bootstrap/ele_seed_bootstrap.sh", "cargo"): 4,
    ("scripts/bootstrap/ele_seed_bootstrap.sh", "rustc"): 4,
    ("scripts/bootstrap/ele_seed_bootstrap.sh", "stage0"): 1,
}

TOKENS: Mapping[str, re.Pattern[str]] = {
    "cargo": re.compile(r"\bcargo\b", re.IGNORECASE),
    # `rustc-hash` is a crate name, not a compiler invocation.
    "rustc": re.compile(r"\brustc\b(?![-_])", re.IGNORECASE),
    "cranelift": re.compile(r"\bcranelift\b", re.IGNORECASE),
    "stage0": re.compile(r"\bstage\s*0\b|\bstage0\b", re.IGNORECASE),
    "project-l": re.compile(r"\bproject[-_]l\b", re.IGNORECASE),
}


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    token: str
    text: str
    classification: str
    allowed: bool
    reason: str | None


@dataclass(frozen=True)
class AuditResult:
    findings: tuple[Finding, ...]

    @property
    def violations(self) -> tuple[Finding, ...]:
        return tuple(f for f in self.findings if f.classification == "active" and not f.allowed)


def _matches_glob(path: str, patterns: Iterable[str]) -> bool:
    candidate = Path(path)
    return any(candidate.match(pattern) for pattern in patterns)


def discover_official_files(root: Path) -> tuple[Path, ...]:
    """Return files from the deliberately scoped official route inventory."""
    found: set[Path] = set()
    for pattern in OFFICIAL_GLOBS:
        found.update(
            p for p in root.glob(pattern)
            if p.is_file() and p.suffix.lower() in TEXT_SUFFIXES
        )
    return tuple(sorted(found, key=lambda p: p.relative_to(root).as_posix()))


def audit_files(
    root: Path,
    files: Iterable[Path],
    *,
    historical_globs: Iterable[str] = HISTORICAL_GLOBS,
    allowlist: Mapping[str, Mapping[str, str]] = ACTIVE_ALLOWLIST,
    allowed_counts: Mapping[tuple[str, str], int] | None = None,
) -> AuditResult:
    findings: list[Finding] = []
    seen_counts: dict[tuple[str, str], int] = {}
    for file in files:
        try:
            relative = file.relative_to(root).as_posix()
        except ValueError:
            continue
        try:
            content = file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            findings.append(
                Finding(
                    path=relative,
                    line=0,
                    token="read-error",
                    text=f"could not audit official file: {exc}",
                    classification="active",
                    allowed=False,
                    reason=None,
                )
            )
            continue
        history = _matches_glob(relative, historical_globs)
        reasons = allowlist.get(relative, {})
        for line_number, line in enumerate(content.splitlines(), 1):
            for token, pattern in TOKENS.items():
                if pattern.search(line):
                    reason = reasons.get(token)
                    key = (relative, token)
                    seen_counts[key] = seen_counts.get(key, 0) + 1
                    count_ok = allowed_counts is None or seen_counts[key] <= allowed_counts.get(key, 0)
                    findings.append(
                        Finding(
                            path=relative,
                            line=line_number,
                            token=token,
                            text=line.strip(),
                            classification="historical" if history else "active",
                            allowed=history or (reason is not None and count_ok),
                            reason="historical migration record" if history else reason,
                        )
                    )
    return AuditResult(tuple(findings))


def audit_repository(root: Path = ROOT) -> AuditResult:
    return audit_files(
        root,
        discover_official_files(root),
        allowed_counts=ACTIVE_REFERENCE_COUNTS,
    )


def _render(result: AuditResult) -> str:
    active = [finding for finding in result.findings if finding.classification == "active"]
    historical = [finding for finding in result.findings if finding.classification == "historical"]
    allowed = sum(f.allowed for f in active)
    lines = [
        f"Stage 0 route audit: {len(active)} active references ({allowed} inventoried), "
        f"{len(historical)} historical references, {len(result.violations)} unlisted active references."
    ]
    for finding in result.findings:
        state = "HISTORY" if finding.classification == "historical" else ("ALLOW" if finding.allowed else "FAIL")
        lines.append(f"{state} {finding.path}:{finding.line}: {finding.token}: {finding.text}")
    return "\n".join(lines)


def _render_violations(result: AuditResult) -> str:
    lines = [
        f"Stage 0 route audit: {len(result.violations)} unlisted active references."
    ]
    lines.extend(
        f"FAIL {f.path}:{f.line}: {f.token}: {f.text}" for f in result.violations
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root to scan")
    parser.add_argument(
        "--enforce",
        action="store_true",
        help="exit non-zero for any active reference missing from the explicit path/token allowlist",
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable findings")
    args = parser.parse_args()
    result = audit_repository(args.root.resolve())
    if args.json:
        print(json.dumps({"findings": [asdict(f) for f in result.findings],
                          "violations": [asdict(f) for f in result.violations]}, indent=2))
    else:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
        print(_render_violations(result) if args.enforce else _render(result))
    return 1 if args.enforce and result.violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
