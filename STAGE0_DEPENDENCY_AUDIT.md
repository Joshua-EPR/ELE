# Stage 0 dependency audit

Audit date: 2026-11-24
Current `main`: `21e9cc32758dc23aa1637fbd4441d9849a6cc677` (PRs #167–#170 merged).
The detailed consumer inventory below was initially collected at `d27dc67`; current compiler/CI status now includes the versioned seeds, value-producing `choose`, native-seed distribution, and owned Text choice matches. PR #169 removes Cargo/Stage 0 distribution fallbacks and packages from verified native seeds. PR #170 implements owned Text payload matches. PR #171 is adding lazy drop-free Option defaults, and PR #172 adds Result/Option propagation; both are still under CI review. These changes do not yet remove the audited Rust/Cargo/Cranelift compiler and historical test dependencies.
Scope: compiler, bootstrap, backend, tests, CI and distribution. ENCA was excluded.

## Latest execution snapshot

- PR #168 (`4444e02`) is merged. Its Linux/Windows native checks and ELF execution passed.
- PR #167 (`2fa0af8`) pins ELF64/PE32+ seed artifacts, removes the Cargo seed job, and validates seed → Gen1′ → Gen2 → Gen3 with compiler tools absent from runner PATH. Linux/Windows bootstrap, full Windows/MSVC, ELF execution, distribution and docs checks passed; merged.
- PR #169 is merged. Required Linux/Windows package, bootstrap, docs and native checks passed after fixing missing `gzip` and nested PowerShell execution under PATH isolation. Distribution now requires a pinned native seed and package archives for installation.
- PR #170 is merged at `21e9cc3`. It adds owned Text payloads to `choice` match lowering and a use-after-move rejection regression; Linux/Windows native checks and ELF execution passed.
- PR #171 (`5227fc8`) implements lazy `??` defaults for drop-free Int/Bool payloads. Owned Text remains an active gap on that branch; required Windows full/MSVC CI is still pending.
- PR #172 (`a7ebe3c`) implements `?` propagation for Option/Result with ownership checks. Required Windows full/MSVC CI is still pending.
- Stage 0, Rust/Cargo and Cranelift remain active in the compiler, historical suites and primary build workflow. Do not declare full independence or remove `crates/l` yet.

## Current branch delta: versioned independent seeds (PR #167)

PR #167 (`codex/versioned-seeds`) merged the seed-job removal. Committed ELF64 and PE32+ seed archives are pinned by `scripts/bootstrap/seeds/manifest.json`; `tools/verify_seed_archive.py` verifies ZIP and executable digests, archive membership, architecture and binary-format identification before extraction. The bootstrap runner adds a scoped `tools/audit_stage0_paths.py --enforce` ratchet, and both OS jobs reduce `PATH` to required runtime utilities so Rust, GCC/Clang, linkers and Stage 0 executables are not resolvable. The audit keeps path-specific migration references and exact counts; historical documents are reported separately. Linux and Windows bootstrap, native execution and full Windows/MSVC checks passed.

## Findings

| Dependency | Location | Use | Necessary now | ELE replacement | Priority |
|---|---|---|---|---|---|
| Stage 0 compiler (`l`) | `crates/l/`, `Cargo.toml` | Rust lexer/parser/sema/LIR, command line and build orchestration | Yes; builds and validates ELE compiler modules | ELE modules exist, but do not replace all compiler and driver paths | P0 |
| Rust and Cargo | `Cargo.toml`, `crates/l/Cargo.toml`, `.github/workflows/native-selfhosting-validation.yml` | Build Stage 0, run integration tests and CI | Yes | None for final compiler/CI yet | P0 |
| Cranelift | `crates/l/Cargo.toml`, `crates/l/src/native.rs`, `crates/l/src/native/*` | Rust implementation of the current native LIR backend; builds Stage 1 and `build-lir` outputs | Yes for the Cranelift path; the alternative invokes `rustc` | ELE CFG backend exists, but does not yet drive the complete final compiler bootstrap | P0 |
| `rustc` backend | `crates/l/src/main.rs` | Provisional LIR-to-Rust transpilation and host compilation; used by some non-Windows Stage 1 test support | Yes for the reference path on some hosts | ELE-native compiler output | P1 |
| Rust build script / platform object | `crates/l/build.rs`, `crates/l/src/native/platform_object.rs` | Builds a Windows platform object for the Rust bootstrap backend | Yes for current Windows builds | ELE platform/runtime emission exists in part; no verified replacement in the bootstrap path | P1 |
| Stage 0-built test harness | `crates/l/tests/stage1_support/mod.rs`, `crates/l/tests/*.rs` | Uses Cargo's `CARGO_BIN_EXE_l` to build Stage 1 fixtures and compare against a reference | Yes for current integration suites | Stage 1+ test runner independent of Cargo/Stage 0 | P1 |
| Stage 0 `build-lir` | `crates/l/tests/stage2_bootstrap_l.rs`, `scripts/bootstrap_stage2.ps1` | Converts Stage 1 emitted LIR into the Stage 2 executable; checks output parity | Yes | ELE native backend invoked as a tested executable generation step | P0 |
| Stage 0/Cranelift in CI | `.github/workflows/native-selfhosting-validation.yml` | Rust setup, Cargo tests, Stage 1 builds, native and distribution checks | Yes; workflow explicitly runs Stage 0-dependent tests | Stage 0-free CI and test bootstrap | P1 |
| Python orchestration | `scripts/package_distribution.py`, development/test scripts | Packages or validates compiler artifacts and invokes build steps | Packaging remains Python-based, but PR #169 removes its Stage 0/Cargo fallback and requires a pinned native seed | Keep Python limited to packaging/test orchestration; distribution binary itself is native ELE | P2 |
| PowerShell/Bash orchestration | `scripts/bootstrap_stage2.ps1`, `scripts/stage3_native_bootstrap_probe.ps1`, install scripts | Local bootstrap, probes and installation | Yes for the current documented script path | Native compiler CLI plus portable packaging/install path | P2 |
| Cache/build output paths | `scripts/package_distribution.py`, `scripts/install.ps1`, workflow artifact paths | Locate Stage 0-built / Stage 1-built executables and generated ELF fixtures | Yes in current distribution and CI flows | Versioned standalone compiler package | P2 |
| C toolchain / platform linker | Compiler backend and workflow build steps | Link objects or produce platform-specific artifacts | Host-specific external build tools remain in current pipeline | Direct ELE image/object writer exists for ELF64 and PE32+, but complete link/runtime coverage is not demonstrated | P1 |

Classification: A = exclusive to Stage 0; B = Cranelift; C = runtime/platform; D = CI; E = tests; F = distribution; G = development tooling that could remain external to the final compiler.

| Class | Current examples | Assessment |
|---|---|---|
| A | Rust compiler in `crates/l/src`, Cargo workspace | Active implementation dependency; no complete ELE replacement demonstrated |
| B | Cranelift dependencies and `native.rs` | Active backend dependency; separate ELE-written backend does not yet displace it |
| C | Rust-generated platform object and backend runtime | Runtime code is split between Rust/Cranelift and ELE modules |
| D | Rust toolchain, Cargo, Stage 0 workflow steps | CI is not Stage 0-free |
| E | `CARGO_BIN_EXE_l`, `stage1_support`, Stage 2 tests | Integration tests still bootstrap or use Stage 0 as reference |
| F | `package_distribution.py`, `install.ps1` cached driver paths | Distribution still expects a Stage 0-built compiler/driver |
| G | Python/PowerShell/Bash scripts | Could remain development tools only after packaging and CI stop depending on them |

## Self-hosting and backend evidence

- `compiler-l/src/` contains ELE implementations for lexer, parser, semantic analysis, driver and code generation. Stage 1 executables are built through Stage 0 in `crates/l/tests/stage1_support/mod.rs`.
- Stage 2 is a bounded LIR parity experiment: `stage2_bootstrap_l.rs` uses `l build-lir` to produce the next executable. It is not a Stage 0-independent compiler rebuild.
- `compiler-l/src/codegen/native_cfg_emit.l`, `elf64.l` and `pe64.l` implement substantial ELE native output. Existing tests demonstrate selected ELF64/PE32+ programs and backend self-rebuild. They do not establish complete compiler independence or full language/ABI coverage.
- `crates/l/src/main.rs` still exposes `rustc` and `cranelift` backends; `crates/l/src/native.rs` lowers CFG LIR to Cranelift IR.
- `scripts/bootstrap_stage2.ps1` defaults to a Cargo-built Stage 0 compiler. `scripts/stage3_native_bootstrap_probe.ps1` also accepts/uses Stage 0 as the starting executable.
- CI installs the Rust toolchain and uses Cargo to build Stage 1. Linux and Windows paths have differing capabilities; Windows is the Cranelift host path while Linux executes generated ELF images after Stage 0-assisted builds.

## External CI check

PR #158 (`3393ff98d4bc84dc216d4ba4c973f7630245f790`) is already merged into inspected `main`. Connected check diagnostics report successful Windows/Linux Stage 0/Stage 1/native ELF and distribution jobs. The differential CFG check was skipped by its condition. These checks do not establish Stage 0 independence because the workflow still invokes Cargo and Stage 0. The connected open-PR query returned no open PRs at audit time.

## Conclusion

Stage 0 removal is not currently safe: there is no complete replacement for the Rust frontend/driver, Cranelift build path, test bootstrap, or distribution path. Keep current dependencies until the staged substitutions and their tests are in place. No ENCA files were inspected for modification or changed.

## Consumer inventory (static audit, file:line)

Second pass, 2026-11-24, read-only. It answers: what breaks if `crates/l` disappears? ENCA was excluded.

### How Stage 0 runs today

- Workspace members: `crates/l` (`project-l`) and `crates/nexo`. Source: `Cargo.toml:2`.
- `crates/nexo` has no dependencies and does not reference `project_l`. It is a separate product, outside the compiler path, touched only by fmt/clippy and the nexo bench scripts.
- Cranelift crates: `crates/l/Cargo.toml:18-23`.
- `l` subcommands: `check`, `build`, `run`, `build-lir`, `run-lir`, and `--backend rustc|cranelift`. Source: `crates/l/src/main.rs:39-64`.
  - The rustc backend shells out to `rustc` (`main.rs:241,260`).
  - The Cranelift backend links with MSVC `link.exe` (`crates/l/src/linker.rs`).
- `crates/l/build.rs` invokes `$RUSTC` for the Win64 platform object.

### Who builds what

| Artifact | Built by today |
|---|---|
| Driver Gen 1 (`compiler-l/src/main_driver.l`) | Stage 0. Cranelift on Windows, rustc backend on Linux. See `stage1_support/mod.rs:74-83`, `native-selfhosting-validation.yml:145-148`, `package_distribution.py:148-157`. |
| Driver Gen 2 / Gen 3 | The ELE driver itself (`package_distribution.py:175-208`) |
| `apps/elepad/**`, `std/**`, `tests/std/*.l` | The ELE driver only. No Stage 0 reference, but the driver used in CI comes from Stage 0. |
| Compiler-l tools (`main_sema`, `main_parser`, `native_cfg_demo`, …) | Stage 0 only, via `stage1_support`. |
| Distribution archive `ele/bin/ele[.exe]` | Gen 3 after a Gen 2 == Gen 3 check (`package_distribution.py:63-75`). Gen 1 comes from `--driver-path`, then `bin/ele*`, then a cached driver, then Stage 0. In CI the Stage 0 fallback is the effective path (`distribution.yml:43`). |

### Cargo test targets (`crates/l/tests/*.rs`, 92 targets)

| Class | Count | Meaning |
|---|---|---|
| Stage 0 frontend/backends | 31 | Use `project_l::` or `CARGO_BIN_EXE_l --backend` directly (e.g. `conformance`, `differential`, `cfg`, `modules`, `references`, `examples_ele_v2`) |
| Stage 0 builds Stage 1/driver, ELE-built program tested — pure | 39 | e.g. `ele_build_driver_l`, `native_*_l`, `window_l`, `file_streams_l`, `stage2_bootstrap_l`, `stage3_native_probe_l` |
| Same, plus Stage 0 library as oracle | 20 | e.g. `sema_l`, `borrow_l`, `lir_l`, `parser_l`, `drops_l`, `stage2_hook_l` |
| Static contracts that still link Stage 0 | 2 | `ele_v2_legacy_ratchet` uses Stage 0 lexer and `check`; `lir_payload_protocol` uses `lir_protocol` |

No test target is free of Stage 0 today.

### Active consumers that break without Stage 0

| Consumer | Location | Class |
|---|---|---|
| All three workflows | `distribution.yml:33-46`, `docs-and-benchmarks.yml:33,58-62`, `native-selfhosting-validation.yml:28-146,179-185,322-328,454-470` | D/E |
| Driver built with `--backend cranelift` for window/ELEPad/console tests | `native-selfhosting-validation.yml:145-197` | B/D |
| `self_coverage_gate.py` reads Stage-0-built tool executables | `native-selfhosting-validation.yml:206`, `tools/self_coverage_gate.py:70-76` | D/G |
| Packaging fallback to Stage 0 | `scripts/package_distribution.py:78-97,148-157` | F |
| Installers fall back to `package_distribution.py` | `scripts/install.ps1:103-105`, `scripts/install.sh:100-101` | F |
| Stage 0 bootstrap scripts | `scripts/bootstrap_stage2.ps1`, `scripts/stage3_native_bootstrap_probe.ps1`, `compiler-l/build-{lexer,parser,sema}.ps1`, `run_full_trace.ps1` | A/B/G |
| Benchmark and verify scripts | `bench/*.ps1` (≈25 scripts call cargo or `l --backend`) | A/B/E/G |
| Contributor gates and getting started | `README.md:257-259`, `README.es.md:257-259`, `docs/getting-started.md:15,51-63`, `std/README.md:37,73,128` | D/F/G |
| Experimental LIR→C backend | `tools/ele_c_backend.py`, `tools/ele_build.py` | G (not on the compiler path; needs a C compiler) |

### Unaffected by removing `crates/l`

These keep working as long as a prebuilt ELE driver (`bin/ele*`) exists:

- `apps/**`, `std/**`, `editors/**`
- `benchmarks/**`
- Installers when given an archive
- `crates/nexo`
- Python/C tools other than `verify_native_cfg_migration.py` and `self_coverage_gate.py`

### Consequence for the removal order

1. **Trust root.** Replace Stage 0 as the trust root with a hash-pinned seed driver.
2. **Driver consumers.** Move the driver consumers onto it: CI GUI/console tests, packaging, installers. These already need only a driver.
3. **Test suite.** Give the 59 class-B test targets a Stage-0-free harness: the driver builds the compiler-l tools.
4. **Oracle tests.** Port the frontend/oracle tests (31 + 20) to driver-based conformance before deleting `crates/l`.
