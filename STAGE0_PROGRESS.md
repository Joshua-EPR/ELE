# Stage 0 removal progress

Updated: 2026-11-24
Current `main`: `3c595759221da0ff9c79d6c8762788241d9f2b71` (PRs #167–#170 and #174 merged).
Current phase: migrate the remaining Stage 0 test/CI paths while closing native compiler gaps.
Estimated completion: **35%** against final acceptance criteria. Seed/bootstrap and compiler slices are verified, while the official compiler/test pipeline and most backend/runtime coverage still use Stage 0, Rust or Cranelift.

## State

- **Blockers:** Full ELE source-to-native compiler rebuild has not been shown independent of Stage 0; Rust/Cargo and Cranelift remain active in compiler and most tests/CI. Linux native execution is verified on Ubuntu CI, not on this Windows host.
- **Risks:** Stage 0 currently implements the production frontend/CLI and Cranelift runtime path. Removing those pieces before a replacement would break currently supported builds and tests.
- **Next phase:** Integrate #171/#172 after their required CI completes; retain `option_default_owned_payload` and `result_propagation` as active gaps, and validate #175 `shape_methods` on both targets.
- **ENCA:** Excluded from this operation; no ENCA changes made.

## Agent work

| Agent | Status | Branch/PR | Files | Tests/evidence | Result |
|---|---|---|---|---|---|
| Engineering director | Active | PRs #171–#175 | Frontend, ELF verifier, audit integration and evidence | #169/#170/#174 merged at `3c59575`; #171/#172/#173/#175 are open and CI is running | Integrating green slices while keeping the Stage 0 retirement boundary explicit. |
| Stage 0 dependency auditor | Complete | None | None | Source audit; no tests run | Dependencies classified A–G; no edits |
| Self-hosting auditor | Complete | None | None | Source audit plus measured Gen chain and 87-program coverage (below) | Driver self-rebuild verified; blockers ranked |
| Static consumer auditor | Complete | `codex/stage0-audit` | `STAGE0_DEPENDENCY_AUDIT.md` | Read-only grep audit with file:line | Consumer inventory integrated |
| Seed/CI engineer | Complete | PR #167 merged at `2fa0af8` | `.github/workflows/stage0-free-bootstrap.yml`, `scripts/bootstrap/seeds/*`, verifier/audit and tests | Linux/Windows bootstrap, docs and distribution checks passed; full Windows/MSVC suite and ELF execution passed. 17 bootstrap/audit tests pass. | Versioned ELF/PE seeds are in main; the transitional Cargo seed job is removed. |
| Frontend choose-expression engineer | Complete | PR #168 merged at `4444e02` | `compiler-l` frontend and corpus regressions | CI passed on Linux/Windows; native corpus and ELF execution checks passed | `choose_expression` is removed from main's known gaps. |
| Choice Text payload engineer | Complete | PR #170 merged at `21e9cc3` | Enum construction/match lowering and corpus regressions | Linux/Windows suites and native ELF execution passed | `choice_text_payload` is removed from main's known gaps. |
| Distribution engineer | Complete | PR #169 merged | Distribution workflow, package builder, installers and docs | Linux/Windows packages, restricted-path installation, bootstrap, docs and distribution checks passed | Distribution requires pinned native seeds and package-only installers; Stage 0 fallbacks are removed from this route. |
| Option default engineer | PR #171 open | `codex/option-default`, head `2210872` | Lazy `??` lowering and corpus regressions | Rebased on `21e9cc3`; Linux and Windows full suites rerunning | Drop-free Int/Bool defaults are implemented; owned Text default remains a documented gap. |
| Result propagation engineer | PR #172 open | `codex/result-propagation`, head `4abcff8` | `?` lowering and ownership regressions; self-coverage baseline | Added exactly one `sema_try.l → lir` baseline row; Windows full/MSVC suite rerunning | `Option`/`Result` propagation is implemented on the branch; CI remains required. |
| Shape methods engineer | PR #175 open | `codex/shape-methods`, head `bd20bd8` | `extend`, receivers and `this` in the existing frontend | PE seed Gen1′→Gen3 fixpoint and full Gen3 corpus: 98 PASS, 2 XFAIL, 0 FAIL/XPASS; Linux/CI pending | Gap is removed only on the branch; cross-target CI is required before integration. |
| Stage 0 path audit | PR #173 open | `codex/audit-script-discovery`, head `20cf653` | `tools/audit_stage0_paths.py`, `tests/bootstrap/test_stage0_path_audit.py`, status docs | 18 bootstrap tests, enforce audit and diff check passed locally; PR CI rerunning after rebase onto `3c59575` | The audit scans `.psm1`/`.cmd`/`.bat` and classifies historical comments separately. |
| ELF verifier | PR #174 merged at `3c59575` | `tools/verify_elf64.py`, `tests/native_backend/test_native_elf_verifier.py` | Eight verifier tests and Linux/Windows CI passed | ELF verifier accepts the generated optional RW/NX segment and rejects invalid mappings; Float and async remain unsupported gaps. |
| Frontend fix (choose on Text, lexer diagnostics) | Complete | PR #161, merged at `ce69d15` | compiler-l frontend, driver regressions, corpus | PR #161 merged; its report records 5 regression tests and corpus 83 pass / 5 XFAIL | Text/Int/Bool choose literals and positioned lexer errors fixed; unrelated expression gap remains. |
| Backend fix (runtime trap diagnostics) | Complete | PR #162, merged at `79b937c` | compiler-l codegen/runtime, trap regression tests | PR #162 merged; seven diagnostic tests and Linux/Windows integration checks reported passing | Native runtime traps now report stderr diagnostics while retaining documented exit codes. |
| Native backend auditor | Complete | None | None | Source audit; no tests run | ELF64/PE64 and Cranelift boundary documented; no edits |

## Pull requests

| PR | Objective | State | CI | Dependencies | Merge |
|---|---|---|---|---|---|
| #158 | ELE v2 migration CI corrections | Merged at `d27dc67` | Connected diagnostics: Linux/Windows and distribution jobs succeeded; differential CFG job skipped | Historical CI fix | Already merged |
| #160 | Native conformance corpus that needs only an ELE compiler | Merged at `bc372e8` | All green; corpus runs in the Stage-0-free jobs | #159 | Merged after review |
| #161 | choose over Text crash + real lexer diagnostics | Merged at `ce69d15` | Merged; see PR diagnostics/history | #160 | Merged |
| #162 | Run-time traps reported on stderr | Merged at `79b937c` | Merged after fixing Linux stderr expectations | #160, #161 | Merged |
| #159 | Stage-0-free seed bootstrap (scripts and CI job) | Merged at `4d034d2` | All checks green, including `bootstrap ELF64/PE32+ without Rust` | None | Merged after review |
| #163 | Stage 0 dependency audit and roadmap | Merged at `2ce8626` | Documentation CI passed | Audit baseline | Merged |
| #164 | Fold constant expressions in the ELE driver frontend | Merged at `8d9d789` | Constant folding now exists in the ELE frontend | #161 | Merged |
| #165 | Run driver regressions and trap diagnostics on Linux | Merged at `049231f` | Linux regression and trap suites wired into CI | #161, #162 | Merged |
| #166 | Structural verification for native PE32+ images | Merged at `91006b9` | Python backend suite and Windows verifier checks passed | None | Merged |
| #167 | Versioned independent ELF/PE seeds and toolchain-free bootstrap | Merged at `2fa0af8` | Linux/Windows bootstrap, full Windows/MSVC, ELF execution, distribution and docs checks passed | #166 | Merged |
| #168 | Value-producing `choose` expressions | Merged at `4444e02` | Linux/Windows and native execution checks green | #161, #164 | Merged |
| #169 | Stage0-free native-seed distribution and package-only installers | Merged | Required Linux/Windows bootstrap, distribution, docs and native checks passed | #167 | Merged |
| #170 | Owned Text payloads in native choice matches | Merged at `21e9cc3` | Required Linux/Windows native checks and ELF execution passed | #168 | Merged |
| #171 | Lazy native Option defaults | Open | Linux passed; Windows full/MSVC suite running at last check | #167–#170 | Pending required checks |
| #172 | Native Option and Result propagation | Open | Linux passed; Windows full/MSVC suite running at last check | #167–#170 | Pending required checks |
| #173 | Scan all Windows bootstrap script types in the Stage 0 audit | Open | Local tests passed; CI rerunning after rebase | #167, #174 | Pending required checks |
| #174 | Validate ELF64 read-write data segments | Merged at `3c59575` | Linux/Windows native, bootstrap, distribution and docs checks passed | #166 | Merged after checks |
| #175 | Native shape extension methods | Open | PE Gen3 corpus and no-Rust bootstrap pass; Linux/CI running | #170 | Pending required checks |

The connected GitHub query above is a historical baseline only. PRs #167–#170 and #174 are merged. Current open work is #171 Option defaults, #172 Result/Option propagation, #173 audit hardening, and #175 shape methods; `option_default_owned_payload` remains active on main.

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

Current `main` known gaps after #170 are `option_default`, `result_propagation`, and `shape_methods`. PR #171 implements drop-free `option_default` cases but retains owned Text as an active gap on its branch; PR #172 implements `result_propagation` and has refreshed self-coverage evidence; PR #175 implements shape methods and has passed the PE Gen3 corpus locally. Required CI is still running. The latest corpus counts are branch-specific and are recorded in the corresponding PR checks.

| Command / check | Platform | Result | Date | Limits |
|---|---|---|---|---|
| `cargo test -p project-l --test stage2_bootstrap_l -- --test-threads=1` | Windows host | 5 passed, 0 failed | 2026-11-24 | ELF64 images were built/structurally checked; native Linux execution was skipped on this host |
| `cargo test -p project-l --test stage3_native_probe_l -- --test-threads=1` | Windows host | 5 passed, 0 failed | 2026-11-24 | Linux ELF execution skipped; native semantic-analyzer parity is opt-in and was skipped |
| PR #158 check diagnostics, head `3393ff98d4bc84dc216d4ba4c973f7630245f790` | GitHub Linux/Windows | Reported checks succeeded; differential CFG was skipped | As reported by connected GitHub check service on 2026-11-24 | PR is merged; checks still exercised Stage 0/Cargo paths |

These checks are evidence for the tested slices only; they do not prove complete self-hosting or Stage 0 independence. Current main additionally includes PRs #161, #162 and #166–#170. PRs #171 and #172 remain open, with CI status recorded above.

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

## Stage-0-free stretch now in CI (PR #159)

`stage0-free-bootstrap.yml` on `origin/main` still has a transitional `seed` job that installs Rust/Cargo and builds the seed. Its Ubuntu and Windows bootstrap jobs remove `cargo`, `rustc` and `rustup` from PATH, assert that none resolves, then:

- checks the seed's SHA-256;
- rebuilds the driver: seed → Gen1' → Gen2 → Gen3;
- requires Gen2 == Gen3 bitwise;
- runs 7 smoke programs, comparing stdout and exit code exactly;
- requires 4 invalid programs to be rejected;
- writes `provenance.json` and `SHA256SUMS`.

Gen2 and Gen3 come out bitwise identical across hosts even when the seeds differ: CI and local seed hashes differed, yet Gen2/Gen3 matched exactly.

PR #167 removed the transitional Cargo seed job and added committed ZIP seeds plus a pinned manifest and archive verifier. Linux/Windows bootstrap and native validation passed. Stage 0 remains active elsewhere in the compiler, primary build/test workflows and historical integration suites.
