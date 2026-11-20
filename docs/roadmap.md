# ELE Development Roadmap

This document outlines the development trajectory of the **ELE Programming Language**, clearly demarcating fully implemented features, experimental components, and future engineering milestones.

---

## 1. Implemented & Verified Capabilities

- [x] **Canonical ELE v2 Surface Grammar:** Declarations with `flow`, `shape`, `choice`, `fixed`; control flow with `when`, `otherwise`, `during`, `each`, `give`.
- [x] **Compile-Time Memory Safety:** Ownership tracking, move semantics, affine types, deterministic drop elaboration, and borrow checker with shared (`view`) and exclusive (`edit`) references.
- [x] **Platform-Independent Intermediate Representation:** `ELE-LIR 1` with formal typestate and lifetime verification.
- [x] **Direct Native x86-64 Backends:**
  - Windows x86-64 (PE32+) image formatter and `kernel32` calling conventions.
  - Linux x86-64 (ELF64) image formatter and direct Linux `syscall` conventions.
- [x] **Autonomous Self-Hosting Driver (`ele build`):**
  - Written 100% in ELE v2.
  - Multi-module dependency discovery and resolution (`take` / `expose`).
  - Circular dependency cycle detection.
  - Filesystem safety: canonical path normalization, multi-module overwrite protection, and `.tmp.ele` atomic staging.
- [x] **3-Generation Bit-for-Bit Fixpoint:** Verified deterministic self-rebuilding on Windows and Linux (Gen 2 SHA-256 == Gen 3 SHA-256; 0 external compiler invocations).
- [x] **Zero CRT Runtime Dependency:** Standalone compiled executables requiring no C standard library or external runtime.

---

## 2. Experimental & In-Progress Features

- [ ] **Expanded Native Self-Coverage:** 20 out of 20 standalone executables currently reach the native backend. Expanding native emission to internal sub-modules (progressing from 20/102 toward full project-wide native emission).
- [ ] **Generic Shapes (`shape of[T]`):** Monomorphization for user-defined generic structures and collections.
- [ ] **Nested Pattern Matching (`choose`):** Advanced pattern guards, slice patterns, and multi-variable destructuring.
- [ ] **LIR Buffer Streaming:** Migrating monolithic in-memory string accumulation to direct streaming I/O during code generation.

---

## 3. Planned Milestones

### Milestone 4.0: Native Backend Optimization
- [ ] SSA (Static Single Assignment) form construction.
- [ ] Graph-coloring or Linear Scan register allocator replacing linear stack slots.
- [ ] Dead code elimination and common subexpression elimination (CSE).
- [ ] Function inlining and loop invariant code motion (LICM).

### Milestone 4.1: Architecture Expansion
- [ ] ARM64 (AArch64) native code generator for Apple Silicon (macOS Mach-O) and Linux ARM64.
- [ ] Windows ARM64 support.

### Milestone 4.2: Standard Library & Concurrency
- [ ] First-class standard library (`std/io`, `std/fs`, `std/net`, `std/sync`).
- [ ] Structured concurrency runtime with cancellation tokens and task nursery scopes (see [ASYNC_MODEL.md](ASYNC_MODEL.md)).

### Milestone 4.3: Tooling & Developer Experience
- [ ] Language Server Protocol (LSP) daemon written in ELE.
- [ ] Multi-error diagnostic recovery in lexer/parser.
- [ ] Official VS Code extension with semantic syntax highlighting and debugging support.
- [ ] Package manager and reproducible build manifest system.
