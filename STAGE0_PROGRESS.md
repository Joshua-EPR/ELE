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
| Self-hosting auditor | Complete | None | None | Source audit plus measured Gen chain and 87-program coverage (below) | Driver self-rebuild verified; blockers ranked |
| Static consumer auditor | Complete | `codex/stage0-audit` | `STAGE0_DEPENDENCY_AUDIT.md` | Read-only grep audit with file:line | Consumer inventory integrated |
| Bootstrap/CI engineer | In progress | `feat/stage0-free-seed-bootstrap` | `scripts/bootstrap/*`, new workflow | Pending | Pending |
| Test/regression engineer | In progress | `test/native-conformance-corpus` | `tests/native_corpus/*` | Pending | Pending |
| Frontend fix (choose on Text, lexer diagnostics) | In progress | `fix/driver-choose-text-and-lexer-diagnostics` | compiler-l frontend | Pending | Pending |
| Backend fix (runtime trap diagnostics) | In progress | `fix/native-runtime-trap-diagnostics` | compiler-l codegen | Pending | Pending |
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

## Capability evidence: ELE driver vs Stage 0

Measured 2026-11-24 on `d27dc67` in a clean worktree (Windows host plus WSL Ubuntu). Nothing was committed by the auditor.

### Generation chain

| Artifact | Built by | SHA-256 |
|---|---|---|
| Gen1 driver (PE) | Stage 0 + Cranelift + `link.exe` | Not reproducible: two builds gave different hashes. Cause not verified. |
| Gen2 = Gen3 = Gen4 (PE) | Gen1, Gen2, Gen3 | `0fa24fe43d0eb3a1290f08f07d9b52bcd6eb91802a4f7ff5e953f1c9ab081ea6` |
| PE built on Linux by Gen2 ELF | Gen2 ELF | Same `0fa24fe4…` (cross-host determinism) |
| Gen1x … Gen5 (ELF) | ELE driver | `77666ed03af34641819becb2d56d642ab2a4256d518037238ddc6436637ed462` |

- **No external processes:**
  - Windows: Gen2/Gen3 builds started no child process; the PE image imports only KERNEL32.
  - Linux: `strace -f -e trace=process` shows only the driver's own `execve`.
- **Build time:**
  - Gen1 (Cranelift-compiled) rebuilds the driver in about 2.8 s.
  - The ELE-compiled driver takes about 13 s, with a peak of about 453 MB.
- **Stage 0 cannot emit an ELF driver.** The Linux chain starts from a PE-hosted cross build.

### Frontend run by the driver

The driver runs these phases:

- modules, lexer and parser
- sema
- move, init, return and leak flow checks
- drop elaboration and the drop verifier
- loan checking
- match exhaustiveness
- the per-function LIR verifier
- the backend verifier

### Coverage

- **Valid programs (76):**
  - The driver compiles 71.
  - 61 match Stage 0 output and exit code on PE and ELF.
  - 0 mismatch on PE. The single ELF mismatch is the GUI test, expected because there is no Linux window backend.
  - The driver also builds 10 programs that Stage 0 cannot (std/elepad import roots, among others).
- **Invalid programs (`examples/invalid`, 11):** all rejected. Three are rejected for the wrong reason (`const_overflow`, `const_runtime`, `mut_receiver`).
- **Compiler tools:** the 22 `compiler-l/src` entry points were built both by Stage 0 and by the driver. 1,467 differential jobs (`main_sema`, `main_parser`, `native_cfg_demo` and others over every `.l`/`.lir` fixture) gave identical stdout, stderr, exit code and output files.

### Blockers to the driver being compiler of record

1. **Trust root.** Gen1 can only come from Stage 0, and no seed binary is published.
   - In progress: seed bootstrap and a Stage-0-free CI job.
2. **Test suite.** All 92 cargo test targets need Stage 0.
   - 26 depend on the Cranelift-only `--trace-alloc` heap trace.
   - 9 depend on `build-lir`/`run-lir`.
   - In progress: Stage-0-free conformance corpus.
3. **Language features rejected by the driver.** Stage 0 accepts all of these:
   - `extend`/methods (`decl.l:206-208`)
   - Float (`lexer.l:264-266`)
   - constant expressions (`sema.l:125-143`)
   - async
   - `of[T]` generics
   - regions, effects (`@noalloc`) and spawn
4. **Compiler crash on valid input.** `choose` on Text crashes the frontend (invalid LIR, rule 2). In progress.
5. **Diagnostics.**
   - Lexer errors are reported as "UTF-8 inválido" with no position. In progress.
   - Runtime traps exit 125/126/127 silently. In progress.

The 26 heap-trace tests depend on an allocation-trace feature that the ELE backend lacks. It needs an ELE-side equivalent before those tests can move.
