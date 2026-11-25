# ELF64 and PE32+ backend coverage

Current main after #173: `ff025e8ac4bff1f183f0c32e556ab326bca7368a`.
Backend source snapshot: `720c25d76709ca0f81cfdbdf27935ccb4fede4b5`.

PR #173 updated audit scripts and did not alter the backend covered here.

This matrix describes the ELE-written LIR/CFG native backend and the emitted
programs. It is not a claim that all ELE syntax or all standard-library APIs
are supported. “Implemented” means the CFG verifier accepts the operation,
the common x86-64 emitter has a lowering, and both target builders provide the
runtime entry it needs. The platform table calls out behavior that differs by
target. A test file is evidence for its cases only; its existence does not
mean every variant in that row is covered.

## Core LIR and CFG operations

The LIR operation IDs are declared in [`lir_build.l`](../compiler-l/src/lir_build.l#L23).
The native CFG reader and verifier are in [`native_cfg_inst.l`](../compiler-l/src/codegen/native_cfg_inst.l#L1),
and instruction/terminator emission is dispatched in
[`native_cfg_emit.l`](../compiler-l/src/codegen/native_cfg_emit.l#L90).

| LIR family | ELF64 Linux | PE32+ Windows | Boundary and evidence |
|---|---|---|---|
| `use`, integer unary and binary arithmetic, comparisons | Implemented | Implemented | Checked integer overflow, divide/remainder by zero, `Int.MIN / -1`, and negating `Int.MIN` trap with status 125. Binary comparisons are scalar; Text equality is outside this backend. See [`native_cfg_arith.l`](../compiler-l/src/codegen/native_cfg_arith.l#L1), [`native_cfg_inst.l`](../compiler-l/src/codegen/native_cfg_inst.l#L211), and `native_arith_l.rs`. |
| Basic blocks, `branch`, `jump`, `return`, `unreachable` | Implemented | Implemented | Conditional branches and block fixups are emitted by the shared CFG emitter. No separate platform control-flow backend. See [`native_cfg_emit.l`](../compiler-l/src/codegen/native_cfg_emit.l#L257). |
| `call` and ordinary returns | Implemented | Implemented | Internal stack calling convention; supports scalar, Text, and aggregate values, including hidden result storage for aggregates. Call arity is bounded at 16. This is not a C/System V/Windows ABI for exported ELE functions. See [`native_cfg_ir.l`](../compiler-l/src/codegen/native_cfg_ir.l#L90) and [`native_cfg_emit.l`](../compiler-l/src/codegen/native_cfg_emit.l#L120). |
| Functions returning references | Partial | Partial | The backend validates a returned borrow only when it derives from a caller-owned reference parameter. Calls to such functions are explicitly rejected (code 141), because the caller-side loan lowering is not implemented. See [`native_cfg_returnref.l`](../compiler-l/src/codegen/native_cfg_returnref.l#L1). |
| Shapes: construction, field read/write, nested layout and by-value passing | Implemented within bounds | Implemented within bounds | Shapes are move-only; Text/list/choice ownership uses drop glue. Up to 64 fields; layout is bounded by `nativeLayoutMaxBytes`; references cannot be embedded as fields. See [`native_cfg_types.l`](../compiler-l/src/codegen/native_cfg_types.l#L100), [`native_cfg_fields.l`](../compiler-l/src/codegen/native_cfg_fields.l#L100), and `native_struct_cfg_l.rs`, `native_nested_struct_l.rs`. |
| Choices: construction, discriminant, checked payload extraction and drop | Implemented within bounds | Implemented within bounds | Up to 64 variants and one payload per variant. Payloads can be Int, Bool, Text, shape, choice or list where their layout is supported. Extraction checks the active tag before loading; mismatch exits 126. See [`native_cfg_types.l`](../compiler-l/src/codegen/native_cfg_types.l#L166), [`native_cfg_emit.l`](../compiler-l/src/codegen/native_cfg_emit.l#L183), and [`native_cfg_list_emit.l`](../compiler-l/src/codegen/native_cfg_list_emit.l#L213). Tests include `native_enum_stage1_payload_l.rs`, `native_enum_payload_l.rs`, and `native_union_drop_l.rs`. |
| `textbuf`, `append`, `print`, `len`, `byteat` and Text `drop` | Implemented | Implemented | Text is an owned three-word value. Linux allocates with `mmap`/`mremap`/`munmap`; Windows uses `VirtualAlloc`/`VirtualFree`. Byte access is bounds checked and exits 127. This does not imply Text comparison support. See [`native_cfg_text.l`](../compiler-l/src/codegen/native_cfg_text.l#L1), [`native_rt.l`](../compiler-l/src/codegen/native_rt.l#L1), and [`win64_heap.l`](../compiler-l/src/codegen/win64_heap.l#L1). |
| `listlit`, `listpush`, `listreserve`, `cap`, `listpop`, indexed places and list `drop` | Implemented within bounds | Implemented within bounds | Lists are move-only; elements may own supported values. Unit elements are rejected. List literals are capped at 4096 elements. Moving an owning value out by index is rejected; use `listpop`. Index errors exit 127. See [`native_cfg_list.l`](../compiler-l/src/codegen/native_cfg_list.l#L1) and [`native_cfg_list_emit.l`](../compiler-l/src/codegen/native_cfg_list_emit.l#L1). Tests include `native_list_l.rs` and `native_corpus_l.rs`. |
| References and local loans | Partial | Partial | Supported forms are reference parameters, checked local loans, field/list-element places, and call-scoped shared/exclusive arguments. References are not general first-class values. Moving owning values through a reference and moving owners out of indexed list places are rejected. Returned-reference calls are also rejected (above). See [`native_cfg_ref.l`](../compiler-l/src/codegen/native_cfg_ref.l#L1), [`native_cfg_loan.l`](../compiler-l/src/codegen/native_cfg_loan.l#L1), and [`native_cfg_inst.l`](../compiler-l/src/codegen/native_cfg_inst.l#L277). |
| Drop, field drop and ownership checks | Implemented within the supported layouts | Implemented within the supported layouts | Whole-value drops release only active owning choice payloads. `dropfield` is limited to a non-indexed shape field that owns heap data. The verifier rejects invalid moves, double drops, out-of-bounds indexes and forged flags. See [`native_cfg_fields.l`](../compiler-l/src/codegen/native_cfg_fields.l#L50), [`native_cfg_list_emit.l`](../compiler-l/src/codegen/native_cfg_list_emit.l#L190), and `native_adversarial_lir_l.rs`. |
| Floats, arrays, multiple payload fields and arbitrary platform extensions | Rejected / not in this CFG type subset | Rejected / not in this CFG type subset | `cfgType` accepts Int, Bool, File, Window, Text in value contexts, shapes, choices and declared lists; Float/F32 and arrays are not representable here. The enum reader accepts zero or one payload. Unknown operation/type codes fail closed. See [`native_cfg_types.l`](../compiler-l/src/codegen/native_cfg_types.l#L5) and [`native_cfg_types.l`](../compiler-l/src/codegen/native_cfg_types.l#L166). |

## Platform operations

Platform opcode names and numeric IDs are in [`lir_build.l`](../compiler-l/src/lir_build.l#L49).
The CFG verifier validates arity and argument modes in
[`native_cfg_platform.l`](../compiler-l/src/codegen/native_cfg_platform.l#L45),
and `cfgBuildFor` selects the Linux or Windows runtime in
[`native_cfg_emit.l`](../compiler-l/src/codegen/native_cfg_emit.l#L419).

| LIR opcodes | ELF64 Linux | PE32+ Windows | Tests and source evidence |
|---|---|---|---|
| 0–5: argument count/lookup, text input, error output, byte output, same-file check | Implemented | Implemented | `native_platform_l.rs`, `native_pe64_platform_l.rs`, and `native_corpus_l.rs`; implementations: `native_rt_platform.l`, `win64_rt_platform.l`. |
| 6–8: console mode, input event, console output | Implemented | Implemented | Routines/imports are emitted only when used. Console event and Windows input behavior are host-console dependent. See `cfgUsesConsole` / `cfgUsesConsoleOutput` in `native_cfg_emit.l`, and `native_platform_l.rs`. |
| 9–16: file open/read/write/seek/size/flush/close/status | Implemented | Implemented | Native syscall file runtime on ELF; Win32 file APIs on PE. `file_streams_l.rs`, `native_platform_l.rs`, `native_pe64_platform_l.rs` cover selected calls and errors. See platform runtime file sections. |
| 17–27: Window open/status/events/drawing/close/cell/text bytes | Unavailable graphical backend; deliberate sentinel behavior | Implemented through Win32 | On Linux, open reports no graphical session, other operations report not-open, and close succeeds as a no-op. This is a functional gap, not window support. Windows integration coverage: `window_l.rs`, `tests/native_backend/win64_window.ps1`, `win64_callback.ps1`. See Linux `pfEmitAll` and Windows `w64EmitPlatform`. |
| 28–29: clipboard write/read | Unavailable; returns platform-unavailable status | Implemented through Win32 clipboard APIs | `native_platform_l.rs`, `native_pe64_platform_l.rs`; Windows implementation in `win64_clipboard.l`. Linux emits unavailable routines in `native_rt_platform.l`. |
| 30: Text from bytes | Implemented | Implemented | Both runtimes validate/convert the input; see `native_platform_l.rs`, `native_pe64_platform_l.rs`, and `tests/std/text_from_bytes.l`. |

On PE32+, runtime imports are generated from the imports actually used by a
program. The PE writer supports fixed-base and relocatable images; the ELF
writer is a static executable writer with no sections, dynamic loader, linker,
or relocation table. These are different image formats around the shared CFG
code generator, not interchangeable object-file backends. See
[`pe64.l`](../compiler-l/src/codegen/pe64.l#L1) and
[`elf64.l`](../compiler-l/src/codegen/elf64.l#L1).

## Test evidence and limits

The focused integration suites are selected in
[`native-selfhosting-validation.yml`](../.github/workflows/native-selfhosting-validation.yml#L50):
Windows runs native enum, heap, CFG, shape, nested-shape, and list tests;
Linux runs the native corpus and selected text/reference/aggregate/platform
tests. The corpus scripts execute real images on their native OS:
[`run.ps1`](../tests/native_corpus/run.ps1) for PE and
[`run.sh`](../tests/native_corpus/run.sh) for ELF. `native_corpus_l.rs`
documents that they are built through Stage 0 during the current transition.

The tests are representative, not exhaustive. In particular, the Linux
window and clipboard operations are intentionally stubs, and a passing
structural PE/ELF verifier proves file-format invariants rather than runtime
behavior. The operation support claims above are based on the target builder,
verifier and runtime emitters; they do not claim complete Stage 1 parity or a
Stage-0-free bootstrap.

On Windows, the focused run was:

```text
cargo test -p project-l --test native_cfg_l --test native_enum_stage1_payload_l --test native_list_l --test native_refs_l --test native_pe64_l --test native_pe64_platform_l --test native_corpus_l -- --test-threads=1
```

Result: 54 passed, 0 failed across the seven test binaries. The PE corpus
execution passed. ELF execution was skipped by the host-gated corpus test
(Windows host; no Linux x86-64 runner/WSL configured), so this run does not
validate ELF runtime behavior.
