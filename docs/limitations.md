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

**Stage 3.5 behavior (native ELE and Windows Stage 0 bootstrap):**

- **Source protection:** Before emitting a result, the driver checks the output against the entry source and each imported module. It performs lexical path normalization, then calls `sameFile` to compare OS file identities where available. The interface is tri-state: `0` = different, `1` = same, `2` = identity could not be established; the driver rejects `1` and `2`. Unlike the earlier implementation, equality of UTF-8 contents is **not** used as file identity.
- **Existing aliases:** OS file identity can detect existing hardlinks and symlinks when opening their targets succeeds. Lexical normalization alone is not filesystem canonicalization; Unicode, UNC/device paths and path-resolution behavior still depend on the host OS.
- **Native output staging:** The Linux ELF64 runtime uses `getrandom` to name a temporary file in the destination directory and opens it exclusively; the Windows PE32+ runtime uses OS-backed randomness and `CreateFileW(CREATE_NEW)`. After checked writes and file flush/sync, it publishes via Linux `rename` or Windows `MoveFileExW` with replacement flags. The Windows **Rust Stage 0 bootstrap object** also now uses CNG `BCryptGenRandom` and exclusive temporary creation. This is materially different from the obsolete double-write `{output}.tmp.ele` implementation.
- **Atomicity scope:** These native rename/replace operations aim to avoid exposing partial output when executed on a filesystem supporting atomic same-directory replacement. They do **not** prove crash durability across power loss or universal atomicity on all filesystems, shares or Windows configurations. No directory `fsync` durability guarantee is currently established.
- **Remaining race limitations:** File identity is checked before compilation, not pinned through publication; another process could change a path or substitute an alias in between (**TOCTOU**). Concurrent writers to the same destination are not serialized; the last successful publication may win. The Rust bootstrap and ELE-native paths must each pass platform-specific failure, concurrency and security tests before stronger guarantees are asserted.
- **Safe use:** Prefer a dedicated build output directory, avoid compiling into locations containing irreplaceable files, and keep backups of valuable source data. A successful CI smoke test is not a formal proof of absence of races or filesystem corruption.

---

## 5. Standard Library & Ecosystem

- **Minimal Builtin Runtime:** Currently limited to:
  - Console output (`print` for integers, booleans, and text).
  - Basic file I/O (`readText`, `writeBytes`).
  - Process termination (`exit`).
- **No Concurrency / Threads Yet:** Structured concurrency primitives, thread pools, and async runtimes are in formal design (see [ASYNC_MODEL.md](ASYNC_MODEL.md)).
- **Package Management:** There is no remote package registry or package manager. Dependencies must be structured as local modules imported via `take`.
