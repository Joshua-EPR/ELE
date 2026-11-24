# Stage 0 removal progress

Updated: 2026-11-24
Current `main`: `4444e0252b07726bac86a2363f7a9be1a4cb960a` (PR #168 merged; PR #167 is still open).
Current phase: finish pinned seed CI, remove Stage 0 from distribution, then close native compiler gaps.
Estimated completion: **35%** against final acceptance criteria. Seed/bootstrap and compiler slices are verified, while the official compiler/test pipeline and most backend/runtime coverage still use Stage 0, Rust or Cranelift.

## State

- **Blockers:** Full ELE source-to-native compiler rebuild has not been shown independent of Stage 0; Rust/Cargo and Cranelift remain active in compiler and most tests/CI. Linux native execution is verified on Ubuntu CI, not on this Windows host.
- **Risks:** Stage 0 currently implements the production frontend/CLI and Cranelift runtime path. Removing those pieces before a replacement would break currently supported builds and tests.
- **Next phase:** Finish CI for #167/#169/#170, integrate green PRs, and continue the remaining `option_default`, `result_propagation`, and `shape_methods` gaps.
- **ENCA:** Excluded from this operation; no ENCA changes made.

## Agent work

| Agent | Status | Branch/PR | Files | Tests/evidence | Result |
|---|---|---|---|---|---|
| Engineering director | Active | PRs #167–#170 | Seed CI, distribution, integration and evidence | PR #168 merged; #167 Windows full suite still running; #169 CI failures fixed at new head; #170 CI pending | Integrating verified slices while keeping the Stage 0 retirement boundary explicit. |
| Stage 0 dependency auditor | Complete | None | None | Source audit; no tests run | Dependencies classified A–G; no edits |
| Self-hosting auditor | Complete | None | None | Source audit plus measured Gen chain and 87-program coverage (below) | Driver self-rebuild verified; blockers ranked |
| Static consumer auditor | Complete | `codex/stage0-audit` | `STAGE0_DEPENDENCY_AUDIT.md` | Read-only grep audit with file:line | Consumer inventory integrated |
| Seed/CI engineer | PR #167 open | `codex/versioned-seeds`, head `4c26152` | `.github/workflows/stage0-free-bootstrap.yml`, `scripts/bootstrap/seeds/*`, verifier/audit and tests | 17/17 bootstrap/audit tests pass; local Windows fixpoint, 7 smoke and 4 reject pass; Linux bootstrap and distribution CI pass; full Windows/MSVC suite remains in progress. | Pinned ELF/PE seeds and isolated bootstrap PATH are implemented; awaiting the final Windows suite. |
| Frontend choose-expression engineer | Complete | PR #168 merged at `4444e02` | `compiler-l` frontend and corpus regressions | CI passed on Linux/Windows; native corpus and ELF execution checks passed | `choose_expression` is removed from main's known gaps. |
| Choice Text payload engineer | PR #170 open | `codex/choice-text-payload`, head `c3840d5` | Enum construction/match lowering and corpus regressions | Prior Gen3 PE corpus: 95 cases, 91 PASS, 4 XFAIL, 0 FAIL/XPASS; rebase onto merged #168 is clean; PR CI pending | `choice_text_payload` implementation and use-after-move rejection are under CI review. |
| Distribution engineer | PR #169 open | `codex/stage0-free-distribution`, head `63ed9cd` | Distribution workflow, package builder, installers and docs | 7 package fixpoint tests and 17 bootstrap/audit tests pass; local restricted-PATH Windows package/install passes. First CI run exposed missing `gzip` and nested `powershell`; fixes pushed and branch rebased onto current main. | Removes Cargo/Stage0 fallbacks and packages only from pinned host-native seeds. |
| Stage 0 path audit | Complete | Local changes included in PR #167 worktree | `tools/audit_stage0_paths.py`, `tests/bootstrap/test_stage0_path_audit.py` | Tests cover allowlisted references, new paths/tokens/counts, history classification, binary seeds and fail-closed reads | Migration allowlist/count gate now runs in both seed jobs. |
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
| #167 | Versioned independent ELF/PE seeds and toolchain-free bootstrap | Open | Linux, bootstrap, distribution and docs green; full Windows/MSVC suite still running at head `4c26152` | #166 | Pending required checks |
| #168 | Value-producing `choose` expressions | Merged at `4444e02` | Linux/Windows and native execution checks green | #161, #164 | Merged |
| #169 | Stage0-free native-seed distribution and package-only installers | Open | First run failed at installer steps; fixes for `gzip` and direct `pwsh` script execution pushed; branch rebased on main at `63ed9cd`, CI rerun pending | #167 | Pending required checks |
| #170 | Owned Text payloads in native choice matches | Open | CI pending; rebased onto main after #168 | #168 | Pending required checks |

The connected GitHub query above is a historical baseline only. Current open PRs and their exact status are listed in the table; #167 is the independent-seed PR, #169 is distribution, and #170 is native choice Text payload support.

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

Current `main` known gaps after #168 are `choice_text_payload`, `option_default`, `result_propagation`, and `shape_methods`. PR #170 targets the first of these. Main's latest native corpus count has not yet been rerun after #168; PR #168's Gen3 PE corpus passed 97 cases (93 PASS, 4 XFAIL), and its Linux execution CI passed.

| Command / check | Platform | Result | Date | Limits |
|---|---|---|---|---|
| `cargo test -p project-l --test stage2_bootstrap_l -- --test-threads=1` | Windows host | 5 passed, 0 failed | 2026-11-24 | ELF64 images were built/structurally checked; native Linux execution was skipped on this host |
| `cargo test -p project-l --test stage3_native_probe_l -- --test-threads=1` | Windows host | 5 passed, 0 failed | 2026-11-24 | Linux ELF execution skipped; native semantic-analyzer parity is opt-in and was skipped |
| PR #158 check diagnostics, head `3393ff98d4bc84dc216d4ba4c973f7630245f790` | GitHub Linux/Windows | Reported checks succeeded; differential CFG was skipped | As reported by connected GitHub check service on 2026-11-24 | PR is merged; checks still exercised Stage 0/Cargo paths |

These checks are evidence for the tested slices only; they do not prove complete self-hosting or Stage 0 independence. Current main additionally includes PRs #161, #162 and #166–#168. PRs #167, #169 and #170 remain open, with CI status recorded above.

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

Remaining trust gap: current main still produces the seed by Stage 0 in that transitional job. PR #167 removes that job and adds committed ZIP seeds plus a pinned manifest and archive verifier; Linux/bootstrap CI and local PE bootstrap pass, while the full Windows/MSVC suite is still running.
