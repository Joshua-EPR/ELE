# Native corpus: known gaps

Cases listed in `known_gaps.txt` keep their **correct** expectation (the
behavior Stage 0 already has and the language documents) and run as XFAIL.
The runners fail with XPASS as soon as one of them starts passing, so each
line below must be removed together with its `known_gaps.txt` entry when the
ELE-written driver gains the feature.

Observed with the driver `compiler-l/src/main_driver.l` built by Stage 0
(Cranelift, Windows) and with the ELF64 driver it rebuilds, on PE32+ and
ELF64 alike: both remaining cases are front-end rejections, so they apply to `all`
targets.

| Case | Driver behavior | Stage 0 behavior |
|---|---|---|
| `option_default_owned_payload` | rejects `Option<Text> ?? fallback` with `error[L0016]` until branch-sensitive ownership/drop lowering is verified | compiles and prints the expected output |
| `result_propagation` | rejects `half(n)?` with `error[L0016]: expresión fuera del subconjunto verificado de Stage 1` | compiles and prints the expected output |

`choose_expression` is implemented through the shared match coverage, arm
testing, payload binding, ownership and result-slot lowering used by the
statement form. The native corpus exercises owned and primitive results.

`option_default` is implemented for drop-free native-supported `Option<T>`
payloads. The positive corpus covers `Some` and `None`, Int and Bool payloads,
and confirms the fallback is evaluated only on the `None` branch. A mismatched
fallback type is rejected with `L0003`. Owner-bearing payloads remain an active
gap: `option_default_owned_payload` has a positive expected-output fixture and
stays in `known_gaps.txt` until branch-sensitive drop handling passes without
LIR verifier errors.

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
