# ELE: A Self-Hosting Systems Programming Language

<p align="center">
  <a href="https://github.com/Joshua-EPR/ELE/actions/workflows/native-selfhosting-validation.yml"><img src="https://img.shields.io/github/actions/workflow/status/Joshua-EPR/ELE/native-selfhosting-validation.yml?branch=main&label=Native%20CI&style=flat-square" alt="Native CI"></a>
  <a href="https://github.com/Joshua-EPR/ELE/actions/workflows/docs-and-benchmarks.yml"><img src="https://img.shields.io/github/actions/workflow/status/Joshua-EPR/ELE/docs-and-benchmarks.yml?branch=main&label=Docs%20%26%20Benchmarks&style=flat-square" alt="Docs CI"></a>
  <img src="https://img.shields.io/badge/Architecture-x86--64-blue?style=flat-square" alt="x86-64">
  <img src="https://img.shields.io/badge/Targets-Windows%20PE32%2B%20%7C%20Linux%20ELF64-success?style=flat-square" alt="Targets">
  <img src="https://img.shields.io/badge/Runtime-Zero%20CRT-informational?style=flat-square" alt="Zero CRT">
</p>

<p align="center">
  <b>English</b> | <a href="README.es.md">Español</a>
</p>

---

## Introduction

**ELE** is an experimental, self-hosting systems programming language designed for deterministic memory safety without a garbage collector. It compiles directly to native machine code (**Windows PE32+** and **Linux ELF64**) with **zero C Runtime (CRT) or standard library dependencies**.

Unlike languages that rely on large runtime layers or external linkers, ELE features an autonomous compiler driver (`ele build`) written 100% in ELE that directly emits executable binary images, plans stack layouts, and verifies affine ownership typestate.

---

## Why ELE?

- **Compile-Time Ownership without GC:** Affine type system with deterministic drop elaboration, move semantics, and borrow checking (`view` shared loans, `edit` exclusive loans).
- **Zero-Dependency Native Binaries:** Produces tiny standalone executables (**~5 KiB**) directly from intermediate representation to x86-64 machine code without linking against `msvcrt.dll`, `ucrt.dll`, or `glibc`.
- **Autonomous Self-Hosting Fixpoint:** Demonstrated 3-generation bit-for-bit reproducible self-rebuilding on both Windows and Linux (`Gen 2 SHA256 == Gen 3 SHA256`, 0 external compiler invocations).
- **Fast Compilation Latency:** Standard modules compile natively in **30–55 ms** with low compiler memory overhead (~24.5 MiB).
- **Clean Canonical Syntax (v2):** Purpose-designed systems grammar with explicit intent: `flow`, `shape`, `choice`, `hold`, `change`, `during`, `when`, `give`.

---

## Quick Start

### 1. Installation

Install ELE using the zero-dependency user installers:

- **Windows:** Run `.\install.ps1` (installs to `$env:LOCALAPPDATA\ele\bin` and configures User PATH).
- **Linux:** Run `./scripts/install.sh` (installs to `~/.ele/bin` and configures shell PATH).

Standalone release packages (`ele-windows-x86_64.zip` and `ele-linux-x86_64.tar.gz`) contain the autonomous compiler binary with zero external toolchain dependencies.

### 2. Minimal Program (`hello.l`)

```ele
// hello.l: Standard entry point in ELE v2 syntax
flow main() {
    print("Hello from native ELE!")
}
```

### 3. Compiling with the Autonomous Driver

Once bootstrapped, ELE compiles source files directly to native executables:

**On Windows:**
```powershell
.\bin\ele.exe build hello.l -o hello.exe
.\hello.exe
# Output: Hello from native ELE!
```

**On Linux:**
```bash
./bin/ele.elf build hello.l --target elf -o hello
chmod +x hello
./hello
# Output: Hello from native ELE!
```

For bootstrapping instructions from source, consult the [Getting Started Guide](docs/getting-started.md).

---

## Language Syntax at a Glance

```ele
// Declarations
shape Vector2 {
    x: Int
    y: Int
}

choice Result {
    Success(value: Int)
    Failure(code: Int)
}

// Functions & Control Flow
flow compute_magnitude(v: view Vector2) => Int {
    give v.x * v.x + v.y * v.y
}

flow main() => Int {
    // Immutable owner binding
    hold pos = Vector2(x: 3, y: 4)

    // Borrowing pos via shared view
    hold mag = compute_magnitude(pos)

    // Mutable variable
    change counter: Int = 0
    during counter < 3 {
        print("Magnitude iteration: {mag}")
        counter = counter + 1
    }

    give 0
}
```

Read the complete [Language Reference](docs/language-reference.md) for detailed specifications of types, collections (`List of[T]`), and borrow checking.

---

## Performance & Benchmarks

All performance claims in ELE are backed by auditable, automated benchmarks executed on physical hardware (Intel x86-64, Windows 10 & WSL2 Ubuntu). No numbers or charts are simulated.

For complete methodology, raw data, and statistical distributions, see [Performance Report](docs/performance.md) and [Benchmark Methodology](docs/benchmarks/methodology.md).

**Measurement provenance:** The Windows results below were recorded on commit [`56f34fb`](https://github.com/Joshua-EPR/ELE/commit/56f34fb437e20ca2b6b5613106f96ec153f36969) (November 20, 2026), **before** the Stage 3.5 merges. They are historical measurements, not fresh measurements of the current `main`. Re-run benchmarks on the integrated compiler before attributing these results to it. The external-comparison suite and standalone runtime suite are separate runs; the runtime table uses the comparison dataset.

### Compilation Latency

ELE compiles small and medium programs in tens of milliseconds:

<p align="center">
  <img src="assets/benchmarks/compilation-time.svg" alt="Compilation Latency" width="760">
</p>

| Workload | Source Lines | Median Compile Time | Compiler Peak RSS | Output Size |
|---|---|---|---|---|
| `hello.l` | 5 | **32.05 ms** | 1.18 MiB | 4,608 B |
| `arithmetic.l` | 10 | **32.90 ms** | 1.21 MiB | 5,120 B |
| `fibonacci.l` | 13 | **35.75 ms** | 1.21 MiB | 5,120 B |
| `text_processing.l` | 10 | **35.24 ms** | 1.20 MiB | 5,120 B |
| `multimodule (main.l)` | 10 | **33.36 ms** | 1.22 MiB | 5,120 B |
| `main_sema.l` (Compiler) | 278 | **3.16 s** | 52.46 MiB | 913,408 B |
| `main_driver.l` (Self-Host) | 692 | **5.23 s** | 87.53 MiB | 1,514,496 B |

---

### Memory Usage During Compilation

Compiler memory overhead is tracked continuously through kernel accounting APIs (Windows Job Objects `PeakProcessMemoryUsed` and Linux `getrusage`):

<p align="center">
  <img src="assets/benchmarks/peak-memory.svg" alt="Compiler Peak Memory" width="760">
</p>

---

### Runtime Performance Comparison

We evaluate identical algorithms across **ELE**, **Rust (`rustc 1.99.1`)**, and **C (`gcc 9.4.0`)** producing verified mathematical outputs:

<p align="center">
  <img src="assets/benchmarks/runtime-performance.svg" alt="Runtime Performance" width="760">
</p>

| Benchmark | Language | Optimization Level | Compile Time | Runtime (ms) | Binary Size |
|---|---|---|---|---|---|
| **Fibonacci(25)** | **ELE** | `native-direct-emit` | 32.79 ms | 53.49 ms | 5,120 B |
| Fibonacci(25) | Rust | Debug (`-O0`) | 670.88 ms | 22.63 ms | 5,086,801 B |
| Fibonacci(25) | Rust | Release (`-O3`) | 716.37 ms | 24.92 ms | 5,085,050 B |
| **Loop(10M)** | **ELE** | `native-direct-emit` | 38.12 ms | 101.34 ms | 5,120 B |
| Loop(10M) | Rust | Debug (`-O0`) | 649.07 ms | 94.34 ms | 5,086,761 B |
| Loop(10M) | Rust | Release (`-O3`) | 690.35 ms | 21.47 ms | 5,084,972 B |

> [!NOTE]
> ELE's native backend emits direct machine code from CFG blocks without SSA optimization passes. Performance varies by workload and settings; these results describe the recorded comparison runs, not an overall ranking of languages.

---

### Binary Footprint

Because ELE binaries do not link against the C runtime library or bundle a heavy standard library runtime, generated executables are orders of magnitude smaller:

<p align="center">
  <img src="assets/benchmarks/binary-size.svg" alt="Binary Footprint Comparison" width="760">
</p>

---

## Self-Hosting & Generational Reproducibility

ELE has established autonomous, bit-for-bit generational self-rebuilding across Windows and Linux.

<p align="center">
  <img src="assets/benchmarks/self-hosting.svg" alt="Self-Hosting Generational Fixpoint" width="760">
</p>

- **Windows Fixpoint:** `Gen 2 SHA256 == Gen 3 SHA256` (`F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D`)
- **Linux Fixpoint:** `Gen 2 SHA256 == Gen 3 SHA256` (`4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9`)
- **External Invocations:** **0** (neither `rustc`, `cargo`, `gcc`, nor `link.exe` are called during Gen 2 and Gen 3 builds).

For the full architectural report, read [Self-Hosting Documentation](docs/self-hosting.md).

---

## Native Pipeline Coverage

<p align="center">
  <img src="assets/benchmarks/native-coverage.svg" alt="Native Coverage Evolution" width="760">
</p>

- **102 / 102 source files (100%)** in `compiler-l/src/` pass the Lexer, Parser, and Semantic Analysis phases.
- **20 / 102 source files (~19.6%)** reach native backend emission; these are the **20 / 20 standalone compiler entry points** in the current coverage matrix. This is not 100% full-source backend coverage.

---

## Compiler Architecture

ELE's compiler pipeline is organized into distinct, modular verification layers:

```text
Source .l ──► Lexer ──► Parser ──► Sema & Types ──► Borrow Checker ──► ELE-LIR ──► CFG ──► x86-64 Emitter ──► PE32+ / ELF64
```

See [Compiler Architecture](docs/architecture.md) for technical deep-dives into Pratt parsing, typestate verification, and x86-64 instruction encoding.

---

## Project Status & Roadmap

ELE is an active research and development systems language. While the compiler driver and standalone programs are fully functional and self-hosted, ELE is not yet recommended for production mission-critical environments.

See [Known Limitations](docs/limitations.md) and [Development Roadmap](docs/roadmap.md) for details on planned features, including ARM64 support, SSA register allocation, and structured concurrency.

---

## Documentation Directory

- [Getting Started Guide](docs/getting-started.md)
- [Language Reference Specification](docs/language-reference.md)
- [Migrating legacy ELE v1 code to ELE v2](docs/MIGRATING_ELE_V1_TO_V2.md)
- [ELE v2 syntax status](docs/ELE_SYNTAX_V2.md)
- [Compiler Architecture](docs/architecture.md)
- [Self-Hosting & Generational Fixpoint](docs/self-hosting.md)
- [Performance & Benchmark Report](docs/performance.md)
- [Known Limitations & Security Constraints](docs/limitations.md)
- [Development Roadmap](docs/roadmap.md)
- [Benchmark Methodology](docs/benchmarks/methodology.md)
- [Benchmark Reproducibility Guide](docs/benchmarks/reproducibility.md)

---

## Contributing & License

Contributions, bug reports, and discussions are welcome. Please ensure that all modifications pass the quality gates:

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test -p project-l --test ele_v2_legacy_ratchet
python benchmarks/scripts/validate_results.py
```

**License:** No repository-level license file has been published. Do not assume redistribution rights without confirming the project's terms.
