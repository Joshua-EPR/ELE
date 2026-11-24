# Stage 0 dependency audit

Audit date: 2026-11-24
Revision inspected: `d27dc67` (`main`, same as `origin/main`)
Scope: compiler, bootstrap, backend, tests, CI and distribution. ENCA was excluded.

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
| Python orchestration | `scripts/package_distribution.py`, development/test scripts | Packages or validates compiler artifacts and invokes build steps | Yes in current package script; not intrinsically required by a future compiler binary | ELE distribution driver or a clearly development-only packaging tool | P2 |
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
