# Self-Hosting Architecture & Generational Fixpoint

This document details the self-hosting capabilities, generational build pipeline, and reproducible bit-for-bit fixpoint verification of the **ELE Programming Language**.

---

## 1. Overview of Self-Hosting in ELE

A programming language is considered self-hosting when a compiler written in that language can compile its own source code to produce a functional executable.

In ELE:
- The unified driver (`compiler-l/src/main_driver.l`) is written **100% in ELE v2 syntax**.
- It incorporates the full compilation pipeline: parsing, semantic analysis, ownership verification, LIR emission, CFG transformation, and native x86-64 machine code generation.
- Stage 3.2 established the first cross-platform generational fixpoint.
- Stage 3.3 hardened this pipeline with strict filesystem safety, atomic staging (`.tmp.ele`), and expanded codegen capacities (32 MiB code / 64 MiB heap reserve).

![Self-Hosting Generations](../assets/benchmarks/self-hosting.svg)

---

## 2. Generational Verification Experiment

The self-hosting reproducibility experiment executes a 3-generation circular compilation process:

```text
       [Stage 0 (Rust Seedling)]
                  │
                  ▼ compiles main_driver.l
           [Gen 1 Binary]
                  │
                  ▼ compiles main_driver.l (Zero external tools)
           [Gen 2 Binary]
                  │
                  ▼ compiles main_driver.l (Zero external tools)
           [Gen 3 Binary]
                  │
                  ▼ Check: SHA256(Gen 2) == SHA256(Gen 3)
```

### Windows x86-64 Chain (PE32+)

| Generation | Binary Image | Size (Bytes) | SHA-256 Digest | External Invocations |
|---|---|---|---|---|
| **Gen 1** | `ele_gen1.exe` | 1,508,352 | *(Bootstrap reference)* | 1 (Stage 0 Rust compiler) |
| **Gen 2** | `ele_gen2.exe` | 1,508,352 | `F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D` | **0** |
| **Gen 3** | `ele_gen3.exe` | 1,508,352 | `F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D` | **0** |

**Bitwise Equality:** `Gen 2 == Gen 3` byte-for-byte identical fixpoint achieved.  
**Functional Verification:** `ele_gen3.exe` compiled `hello.l` to `hello_by_gen3.exe`, which ran with exit code 0.

### Linux x86-64 Chain (ELF64 / WSL2 Ubuntu)

| Generation | Binary Image | Size (Bytes) | SHA-256 Digest | External Invocations |
|---|---|---|---|---|
| **Gen 1** | `ele_gen1.elf` | 1,511,424 | *(Built by ELE driver)* | **0** |
| **Gen 2** | `ele_gen2.elf` | 1,511,424 | `4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9` | **0** |
| **Gen 3** | `ele_gen3.elf` | 1,511,424 | `4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9` | **0** |

**Bitwise Equality:** `Gen 2 == Gen 3` byte-for-byte identical fixpoint achieved.  
**Functional Verification:** `ele_gen3.elf` compiled `hello.l` in Linux to `hello_by_gen3.elf`, which executed natively with exit code 0.

---

## 3. Scope of Self-Hosting & Autocobertura

While the driver `main_driver.l` is fully self-hosted, we maintain strict scientific accuracy regarding project-wide coverage:

- **Compiler Driver:** 100% self-hosted and self-rebuilding.
- **Standalone Executables:** 20 out of 20 standalone tools in `compiler-l/src/` reach the native backend (100% of standalone executables).
- **Total Repository Sources:** 102 source files in `compiler-l/src/`:
  - **102 / 102 (100%)** reach the Lexer & Parser phase.
  - **102 / 102 (100%)** reach Semantic Analysis.
  - **102 / 102 (100%)** reach ELE-LIR lowering.
  - **20 / 102 (19.6%)** compile to standalone native executables (the remaining 82 files are sub-modules imported by the standalone drivers).

![Native Pipeline Coverage](../assets/benchmarks/native-coverage.svg)

---

## 4. Reproducing the Self-Hosting Fixpoint

To reproduce the exact generational verification on your machine:

```powershell
# Set distro environment for Linux execution on Windows hosts
$env:ELE_TEST_WSL_DISTRO = "Ubuntu"

# Run the full integration test suite verifying fixpoints
cargo test -p project-l --test ele_build_driver_l driver_builds_self_rebuild_windows_fixpoint
cargo test -p project-l --test ele_build_driver_l driver_builds_self_rebuild_linux_fixpoint
```
Both tests assert bitwise equality (`assert_eq!(bytes_gen2, bytes_gen3)`) and execute the Gen 3 binary.
