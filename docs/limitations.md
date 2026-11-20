# Known Limitations & Technical Constraints

This document provides transparent, verified engineering disclosure regarding current boundaries, experimental features, and limitations in the **ELE Programming Language**.

---

## 1. Platform & Architecture Constraints

- **Architectures:** Only **x86-64** (Intel/AMD 64-bit) is supported. ARM64 (AArch64), RISC-V, and 32-bit x86 are not implemented.
- **Operating Systems:**
  - **Supported:** Windows x86-64 (PE32+ executable format) and Linux x86-64 (ELF64 format).
  - **Unsupported:** macOS (Mach-O), FreeBSD, WebAssembly, and embedded targets.

---

## 2. Code Generation & Optimization Boundaries

- **No SSA / Register Allocator:** The native backend emits machine instructions directly from basic block CFGs with a simple linear stack-frame convention. There is no SSA transformation, global register allocation, or loop vectorization.
- **Runtime Performance Profile:**
  - Executable latency is comparable to unoptimized debug builds of C and Rust.
  - Highly optimized C/Rust (`-O3`) code utilizing AVX2/SSE SIMD instructions or loop unrolling achieves higher throughput on tight mathematical kernels.
- **Code & Capacity Limits:**
  - Maximum generated code size: **32 MiB** (`ELF64_MAX_CODE` / `PE64_MAX_CODE = 33554432`). Binaries strictly exceeding 32 MiB (`size > 33554432`, tested at 33,554,433 bytes) fail-closed with clear error diagnostics.
  - Dynamic heap allocator boundary: accepts allocations up to and including **exactly 32 MiB** (`NATIVE_HEAP_MAX = 33554432`), rejecting strictly larger requests (`size > 33554432`) via `heapDynSizeGuard`.
  - Maximum stack frame layout for aggregates: **1 MiB** (`NATIVE_LAYOUT_MAX_BYTES = 1048576`).
  - PE32+ heap reservation: **64 MiB** (`SizeOfHeapReserve = 67108864`).

---

## 3. Surface Language & Stage 1 Compiler Restrictions

- **Temporary Aggregate Projections (L0016):**
  Chaining field access directly on a function returning an aggregate value (e.g. `layoutOf(...).error`) is rejected by the Stage 1 subset. The result must be bound to a local owner first:
  ```ele
  // Rejected:
  // when pe64Layout(...).error != 0 { ... }

  // Required:
  hold layout = pe64Layout(...)
  when layout.error != 0 { ... }
  ```
- **String Concatenation:**
  ELE does not currently feature a binary `+` operator for `Text`. String joining is accomplished via string interpolation (`"{a}{b}"`).
- **Single-Error Frontend Bailout:**
  The native parser and semantic analyzer abort on the first syntax or ownership violation rather than recovering to produce a comprehensive multi-diagnostic report.

---

## 4. Filesystem & Driver Safety Guarantees

- **Lexical Path Normalization:** The driver normalizes separators and `.` / `..` as text, but this is **not** OS-backed filesystem canonicalization. Absolute/relative aliases, UNC/device paths, Unicode and symlink identities are not reliably resolved.
- **Multi-Module Protection (Limited):** It compares the requested destination with the entry source and imported modules by textual path and a supplementary UTF-8 content heuristic. Equal content does not prove that two paths refer to the same file, and hardlink identity is not established.
- **Output Writing Is Not Atomic:** The driver writes `{output}.tmp.ele` and then performs a separate `writeBytes(output, image)` call. **There is no atomic rename/replace**. An interrupted final write may truncate or corrupt the destination, and the temporary file may remain.
- **Precaution:** Do not target irreplaceable files or unverified aliases. Keep backups until OS-level file identity checks, safe temporary-file handling, and atomic publication are implemented and tested.

---
## 5. Standard Library & Ecosystem

- **Minimal Builtin Runtime:** Currently limited to:
  - Console output (`print` for integers, booleans, and text).
  - Basic file I/O (`readText`, `writeBytes`).
  - Process termination (`exit`).
- **No Concurrency / Threads Yet:** Structured concurrency primitives, thread pools, and async runtimes are in formal design (see [ASYNC_MODEL.md](ASYNC_MODEL.md)).
- **Package Management:** There is no remote package registry or package manager. Dependencies must be structured as local modules imported via `take`.
