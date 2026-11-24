# Stage 0 removal roadmap

Status date: 2026-11-24. This roadmap reflects the inspected repository at `d27dc67`; it is an execution order, not a claim of completion.

## Phase 0 — Baseline and evidence (in progress)

- [x] Inspect local `main`, recent commits, dependency manifests, bootstrap scripts, workflow, tests and distribution paths.
- [x] Check PR #158 CI diagnostics. It is already merged; reported active checks succeeded, with the differential CFG job skipped by condition.
- [x] Inventory current Stage 0, Cargo, Cranelift, tests, CI and distribution dependencies in `STAGE0_DEPENDENCY_AUDIT.md`.
- [x] Obtain Linux native execution evidence. ELF Gen2..Gen5 have identical hashes in WSL, and CI `bootstrap ELF64 without Rust` passes.
- [ ] Reconcile audit against any newly opened PRs and current default-branch workflow runs.

## Phase 1 — Define the replaceable compiler boundary

- [ ] Specify the complete source-to-LIR and LIR-to-image contracts already used by the ELE modules.
- [ ] Establish explicit coverage for every compiler source module, import closure, diagnostics, runtime and target.
- [ ] Keep the Stage 0 compiler as the reference oracle while verifying each replacement.
- Exit criteria: coverage report is generated from actual builds and identifies unsupported constructs without deleting tests.

## Phase 2 — Successive native compiler generations

- [ ] Build the full compiler entry point from ELE sources using the ELE native backend.
- [x] Have generated generation N compile the same compiler sources into generation N+1. Verified fixed point: Gen2 = Gen3 bitwise on PE and ELF, enforced in CI by PR #159.
- [ ] Run appropriate compiler/runtime suites under each generation, with Stage 0 only as a comparison oracle.
- [ ] Compare behavior and deterministic LIR/image output; document expected metadata differences.
- Exit criteria: at least generations 1–3 pass the same declared validation set and rebuild the compiler.

## Phase 3 — Complete native target and runtime coverage

- [ ] Close ELF64 gaps across ABI, calls, memory, aggregates, strings/lists, ownership/drop, error handling and IO.
- [ ] Close PE64 gaps across ABI, calls, memory, aggregates, runtime/IO and Windows subsystem requirements.
- [ ] Verify generated images on actual Linux and Windows runners, not only structural inspection or cross-platform emission.
- Exit criteria: native compiler generations pass the supported-language conformance suites on both targets.

## Phase 4 — Remove bootstrap dependencies from CI and distribution

- [x] Add a reproducible bootstrap from a hash-checked seed without Rust/Cargo/Cranelift (PR #159). The seed is still produced by Stage 0.
- [ ] Publish a hash-pinned seed release and remove the transitional `seed` job. Publishing needs the owner's approval.
- [x] First Stage-0-free regression suite: `tests/native_corpus`, 85 cases, run with Gen3 in CI (PR #160).
- [ ] Migrate the remaining tests to generated ELE compiler generations while retaining Stage 0 differential tests in a separate compatibility job during transition.
- [ ] Remove Cargo/Cranelift installation from final compiler jobs only after the new path proves parity.
- [ ] Package and install the standalone compiler from clean Linux and Windows environments.
- Exit criteria: CI, distribution and install verification pass with Stage 0 and Cranelift absent.

## Phase 5 — Retire Stage 0

- [ ] Confirm no active references in compiler, tests, CI, scripts or distribution.
- [ ] Remove Rust/Cranelift compiler implementation and bootstrap-only artifacts after replacements are merged and validated.
- [ ] Keep historical bootstrap provenance and reproducibility documentation.
- Exit criteria: final audit and successful clean-room bootstrap on both platforms.

## Current technical boundary

Stage 1 source modules, a Stage 2 parity harness, ELE-written native CFG/ELF64/PE32+ generation, and selected Stage 3 self-rebuild probes exist. Current tests prove only slices of that path. The compiler CLI, semantic frontend, Cranelift backend, test bootstrap and distribution still depend on Stage 0. Removing Stage 0 now would remove working capabilities before replacements exist.
