# ELE Compiler Architecture

This document describes the compilation pipeline, intermediate representations, native code generation backends, and self-hosting architecture of the **ELE Programming Language**.

---

## 1. High-Level Compiler Pipeline

```text
               Source Code (*.l)
                       │
                       ▼
                 [Lexer & Spans]
                       │ Tokens UTF-8
                       ▼
                    [Parser]
                       │ Abstract Syntax Tree (AST)
                       ▼
              [Semantic Analyzer]
                       │ Types, Scopes, Monomorphization
                       ▼
          [Ownership & Borrow Checker]
                       │ Drop Flags, Two-Phase Loans, Moves
                       ▼
                   [ELE-LIR]
                       │ Platform-Independent Linear IR
                       ▼
                [LIR Verifier]
                       │ Typestate & Invariant Verification
                       ▼
              [Native CFG Lowing]
                       │ Basic Blocks, Stack Frame Layout
                       ▼
            [x86-64 Machine Encoder]
                       │ Direct Intel 64 Instruction Emission
           ┌───────────┴───────────┐
           ▼                       ▼
    [PE32+ Writer]          [ELF64 Writer]
    Windows x86-64          Linux x86-64
      Executable              Executable
```

---

## 2. Compilation Stages

### Phase 1: Lexical Analysis & Tokenization
- Implemented in `compiler-l/src/lexer.l`, `tokens.l`.
- Enforces strict UTF-8 validity.
- Tracks source byte spans and line/column indices for compiler diagnostics.
- Tokenizes string interpolation tokens (`"prefix {expr} suffix"`).

### Phase 2: AST Construction
- Implemented in `compiler-l/src/parser.l`, `decl.l`, `expr.l`, `stmt.l`.
- Pratt parsing algorithm for expressions with unambiguous precedence.
- Structured AST representations for shapes, choices, and control flow.

### Phase 3: Semantic Analysis & Typing
- Implemented in `compiler-l/src/sema.l`, `sema_types.l`, `sema_stmt.l`, `sema_expr.l`.
- Type checking with local inference.
- Module resolution and visibility enforcement (`take` / `expose`).
- Circular import detection via dependency graph cycle analysis.

### Phase 4: Ownership Analysis & Drop Elaboration
- Implemented in `compiler-l/src/ownership_l.l`, `loans_l.l`, `loans_check.l`, `sema_drop.l`.
- **Borrow Checker:** Verifies shared (`view`) and exclusive (`edit`) loans. Rejects use-after-move, double-free, and simultaneous aliasing of exclusive loans.
- **Drop Flags:** Elaborates deterministic drop glue for heap-allocated structures (`Text`, `List of[T]`, owned choices, and structs).

### Phase 5: ELE-LIR & Formal Verification
- Implemented in `compiler-l/src/lir_build.l`, `lir_verify.l`, `lir_emit.l`.
- Platform-independent text intermediate representation (`ELE-LIR 1`).
- The LIR Verifier validates typestate, stack places, and lifetime constraints before code generation commences.

### Phase 6: Native Backend & Code Generation
- Implemented in `compiler-l/src/codegen/`.
- **Control Flow Graph (CFG):** Decomposes LIR into basic blocks with explicit branch targets (`native_cfg_ir.l`).
- **Layout Planner:** Sizes stack frames, aligns local places to 8/16-byte boundaries, and plans calling conventions (`native_layout.l`).
- **Instruction Encoder:** Directly encodes x86-64 instructions (REX prefixes, ModR/M, SIB, 32-bit displacements and immediates) in `x86_64.l`.
- **Image Formatters:**
  - `pe64.l`: Formats MS-DOS stub, PE32+ headers, `.text` and `.data` sections, and import directory tables for Windows NT kernel (`kernel32.dll`).
  - `elf64.l`: Formats ELF64 header, program headers (`PT_LOAD`), `.text` code section, and entry point for Linux `sys_enter`.

---

## 3. Runtime Architecture & Zero CRT Dependency

ELE executables are **100% self-contained**:
- **No C Runtime (CRT):** Compiles without linking against `msvcrt.dll`, `ucrt.dll`, or `glibc`.
- **Direct System Calls & Platform Wrappers:**
  - **Windows:** Resolves `ExitProcess`, `GetStdHandle`, and `WriteFile` dynamically or through minimal direct import tables.
  - **Linux:** Emits direct `syscall` instructions (`sys_write` [1], `sys_exit` [60], `sys_mmap` [9], `sys_munmap` [11]).
- **Dynamic Heap Allocator & Capacity Guards:**
  - Dynamic heap operations in `compiler-l/src/codegen/native_heap_dynamic.l` enforce `NATIVE_HEAP_MAX = 33554432` (32 MiB).
  - The size guard (`heapDynSizeGuard`) accepts allocations up to and including **exactly 32 MiB** (`size <= 33554432`), rejecting strictly larger requests (`size > 33554432`) without heap corruption.
- **Binary Footprint:** A standard compiled binary is typically between **4.5 KiB and 6.0 KiB**, compared to ~5 MiB for compilers that bundle a standard runtime library.

---

## 4. Bootstrap Architecture: Stage 0 vs Stage 1 / Stage 2

To maintain rigor, ELE clearly distinguishes between its development bootstrap tools and its self-hosted compiler:

1. **Stage 0 Bootstrap (`crates/l/` in Rust):**
   - Serves as the bootstrapping seedling to compile the initial ELE compiler written in ELE.
   - Built via `cargo build -p project-l --bin l`.
2. **Stage 1 Compiler (`compiler-l/` in ELE):**
   - The complete compiler (Lexer, Parser, Sema, LIR, Code Generation, and Driver) written entirely in ELE.
   - Compiles `.l` sources directly to standalone PE32+ and ELF64 binaries.
3. **Stage 2 / Stage 3 Fixpoint:**
   - The Stage 1 binary compiles its own source code (`main_driver.l`) to produce Generation 2 (`ele_gen2`).
   - Generation 2 compiles the source code again to produce Generation 3 (`ele_gen3`).
   - `ele_gen2` and `ele_gen3` achieve **100% bitwise identity**, demonstrating complete self-hosting reproducibility without external compiler invocations.
