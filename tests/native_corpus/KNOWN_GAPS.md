# Native corpus: known gaps

Cases listed in `known_gaps.txt` keep their **correct** expectation (the
behavior Stage 0 already has and the language documents) and run as XFAIL.
The runners fail with XPASS as soon as one of them starts passing, so each
line below must be removed together with its `known_gaps.txt` entry when the
ELE-written driver gains the feature.

The current `known_gaps.txt` has no active entries. The corpus runner still
rejects XPASS if a future entry passes, and rejects a listed case if it is not
also documented here.

`choose_expression` is implemented through the shared match coverage, arm
testing, payload binding, ownership and result-slot lowering used by the
statement form. The native corpus exercises owned and primitive results.

`option_default` is implemented for native-supported `Option<T>` payloads,
including owned `Text`. The positive corpus covers `Some` and `None`, Int,
Bool, and Text payloads, lazy function fallbacks, and literal fallbacks. A
mismatched fallback type is rejected with `L0003`; reusing a moved owned
payload is rejected with `L0005`.

`result_propagation` is implemented for `Option<T>?` and `Result<T, E>?` in the
existing native frontend. The success payload flows into the expression result;
the None/Err branch propagates from the enclosing function, and `Result` error
types must match. Positive corpus cases cover both branches and owned payloads;
negative cases cover incompatible return/error types and use after consumption.

## Stage 0 divergences (not driver gaps)

Stage 0 was used to cross-check every expectation. Where it disagrees, the
corpus follows the ELE-written native backend, whose contract is documented
in `compiler-l/src/codegen/native_cfg_arith.l`, `native_cfg_emit.l` and
`native_rt_platform.l`:

- **Run-time traps.** Overflow, division or remainder by zero and
  `Int.MIN / -1` exit with status **125**; out-of-range `byteAt` or list
  indices exit with **127**. The Stage 0 executable prints the same stdout,
  then reports `ELE <line>:<col>: overflow entero o división/resto por cero`
  (or `índice fuera de rango`) on stderr and aborts with
  `STATUS_STACK_BUFFER_OVERRUN` (0xC0000409) on Windows. Affected cases:
  `overflow_*`, `div_by_zero`, `rem_by_zero`, `div_min_by_minus_one`,
  `rem_min_by_minus_one`, `recursion_overflow`, `list_index_*`,
  `text_byteat_*`.
- **`deep_recursion`.** 100000 nested calls overflow the 1 MiB main-thread
  stack of the Stage 0 (rustc backend) executable; the native image runs it.
- **`choice_state_machine`.** Stage 0 rejects `l = next(l)` inside a loop
  (`L0005 movimiento de valor exterior dentro de bucle no soportado`); the
  driver accepts it, correctly, because `l` is reinitialized in the same
  iteration it is moved.
- **Diagnostics.** Reject cases assert the driver's codes and positions.
  Stage 0 rejects every one of them too, often with a different code or
  column (for example `L0001` where the driver reports `L0004`/`L0006`).
- **Not covered:** `Text == Text` is rejected by both compilers (Stage 0:
  `feature not implemented: operadores sobre Text`), so the corpus does not
  assert it yet.
