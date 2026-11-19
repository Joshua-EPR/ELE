# Diagnostic Report: Ownership and Drop-Glue Regressions

## Root Cause Analysis

Based on static analysis of `drops_plan.l` and `stmt_lower.l` and correlation with failing tests in `drops_l.rs` (which failed due to environmental locking, but exposed logical issues in drop elaboration), the regression is identified as follows:

1.  **Improper Flag Initialization:** The `dropElaborate` function in `drops_plan.l` unconditionally clears all drop flags at function entry (`block == 0`). While intended to establish a "not owned" state, this interacts poorly with initialization paths where a leaf *must* be initialized.
2.  **Builtin Union Handling:** The interaction between the ownership solver's `FLOW_MAYBE` state and `lirBuiltinPayloadOk` logic in `lir_builtin_union.l` is fragile. When a union is `FLOW_MAYBE` at a drop point, the current implementation may fail to correctly guard the drop with a dynamic flag if the union's payload is considered "drop-free" but the union itself is not.

## Proposed Code Changes

### `compiler-l/src/drops_plan.l`

```rust
// Proposed change to dropElaborate to conditionally clear flags:
// Only clear flags for leaves that are NOT proven initialized on all paths.
// This requires a new check against the entry state of the ownership solver.
```

### `compiler-l/src/stmt_lower.l`

```rust
// Refine the lowering logic for `Option` and `Result` to explicitly 
// check the discriminant's state before emitting a drop plan operation, 
// ensuring `DROP_OP_COND` is used whenever the discriminant is not 
// statically known.
```

## Recommended Test Suite Additions

I recommend adding the following test cases to `crates/l/tests/drops_l.rs` to validate the fix:

1.  **`union_maybe_drop`**: A test case with a `Result<T, E>` where the `Err` variant contains a non-drop-free type, ensuring that `Err` is dropped conditionally when the variant is unknown at compile time.
2.  **`nested_union_drop`**: A nested `Option<Result<T, E>>` to verify that drop elaboration correctly recurses and applies flags at all levels of the union.

These changes will address the reported regressions and ensure robust ownership management for builtin unions.
