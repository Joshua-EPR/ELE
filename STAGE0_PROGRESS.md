# Stage 0 removal progress

Updated: 2026-11-24
Inspected revision: `d27dc67` on `main` (`origin/main`)
Current phase: Baseline/evidence and architecture boundary.
Estimated completion: **15%** against the requested final acceptance criteria. This is a coarse estimate: several native output and generation probes exist, while compiler, backend, CI and distribution independence remain unmet.

## State

- **Blockers:** Full ELE source-to-native compiler rebuild has not been shown independent of Stage 0; Rust/Cargo and Cranelift remain active in compiler, tests, CI and distribution. Windows host did not execute Linux ELF64 images in the local probe.
- **Risks:** Stage 0 currently implements the production frontend/CLI and Cranelift runtime path. Removing those pieces before a replacement would break currently supported builds and tests.
- **Next phase:** Define measurable module/feature coverage and complete native generation validation on Linux and Windows; then migrate one bootstrap/test path at a time.
- **ENCA:** Excluded from this operation; no ENCA changes made.

## Agent work

| Agent | Status | Branch/PR | Files | Tests/evidence | Result |
|---|---|---|---|---|---|
| Engineering director | Active | Current checkout; no PR created | Audit, roadmap, progress documents | Git state, workflow and source inspection; local tests below | Integrated read-only audit findings |
| Stage 0 dependency auditor | Complete | None | None | Source audit; no tests run | Dependencies classified A–G; no edits |
| Self-hosting auditor | Complete | None | None | Source audit; no tests run | Stage 1/2/3 boundaries and gaps documented; no edits |
| Native backend auditor | Complete | None | None | Source audit; no tests run | ELF64/PE64 and Cranelift boundary documented; no edits |

## Pull requests

| PR | Objective | State | CI | Dependencies | Merge |
|---|---|---|---|---|---|
| #158 | ELE v2 migration CI corrections | Merged at `d27dc67` | Connected diagnostics: Linux/Windows and distribution jobs succeeded; differential CFG job skipped | Historical CI fix | Already merged |
| New Stage 0 work | None created during baseline | None | N/A | Audit and validated implementation slice required | N/A |

The connected GitHub query returned no open PRs at the time of inspection.

## Dependency snapshot

| Dependency | Current use | Replacement | State |
|---|---|---|---|
| Rust/Cargo Stage 0 | Compiler, tests, CI, package bootstrap | Full ELE compiler build and test entry point | Active; P0 |
| Cranelift | Stage 0 native backend and `build-lir` bootstrap | ELE native CFG backend as final build path | Active; P0 |
| `rustc` | Reference LIR backend on some paths | ELE native build and runtime | Active; P1 |
| Python/PowerShell/Bash | Package/bootstrap/test orchestration | Development-only tools or ELE distribution driver | Active in current flows; P2 |
| ELF64/PE64 emitters | ELE-written image generation | Complete native target/runtime validation | Partial implementation; validation incomplete |

Full inventory and locations: `STAGE0_DEPENDENCY_AUDIT.md`.

## Test and CI evidence

| Command / check | Platform | Result | Date | Limits |
|---|---|---|---|---|
| `cargo test -p project-l --test stage2_bootstrap_l -- --test-threads=1` | Windows host | 5 passed, 0 failed | 2026-11-24 | ELF64 images were built/structurally checked; native Linux execution was skipped on this host |
| `cargo test -p project-l --test stage3_native_probe_l -- --test-threads=1` | Windows host | 5 passed, 0 failed | 2026-11-24 | Linux ELF execution skipped; native semantic-analyzer parity is opt-in and was skipped |
| PR #158 check diagnostics, head `3393ff98d4bc84dc216d4ba4c973f7630245f790` | GitHub Linux/Windows | Reported checks succeeded; differential CFG was skipped | As reported by connected GitHub check service on 2026-11-24 | PR is merged; checks still exercised Stage 0/Cargo paths |

These checks are evidence for the tested slices only; they do not prove complete self-hosting or Stage 0 independence.
