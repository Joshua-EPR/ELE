# Migrating legacy ELE v1 code to ELE v2

ELE v2 changes the language's surface syntax while keeping the compiler's
existing type and ownership rules. Migrate one construct at a time, then run
the compiler and tests; do not apply global text replacements to source files.
Strings, comments, field names, and method calls can contain the same words as
keywords, and several changes affect meaning as well as spelling.

## Core syntax changes

| Legacy v1 | ELE v2 |
| --- | --- |
| `fn` | `flow` |
| `struct` | `shape` |
| `enum` | `choice` |
| `impl` | `extend` |
| `pub` | `expose` |
| `let` / `var` | `hold` / `change` |
| `const` | `fixed` |
| `return value` | `give value` |
| `-> T` | `=> T` |
| `if` / `else` | `when` / `otherwise` |
| `for x in xs` | `each x among xs` |
| `while` / `loop` | `during` / `repeat` |
| `break` / `continue` | `leave` / `proceed` |
| `match` | `choose` |
| `import` | `take` |
| `self` | `this` |
| `&T` / `&mut T` | `view T` / `edit T` |
| `Vec<T>`-style generic application | `List of[T]`-style application |

ELE v2 uses `@` for method and associated calls, while `.` remains field
access: `point.x` reads a field and `point@move(1)` calls a method. In a
`choose`, write a colon between each pattern and its body. Generic calls use
`identity of[Int](42)`. These forms are not interchangeable with a mechanical
keyword substitution.

## Example

Legacy:

```ele
struct Counter { value: Int }
impl Counter {
    fn add(&mut self, amount: Int) -> Int {
        self.value += amount
        return self.value
    }
}
fn main() -> Int {
    let mut counter = Counter(value: 0)
    if counter.add(42) > 0 { return counter.value }
    return 0
}
```

ELE v2:

```ele
shape Counter { value: Int }
extend Counter {
    exclusive flow add(amount: Int) => Int {
        this.value += amount
        give this.value
    }
}
flow main() => Int {
    change counter = Counter(value: 0)
    when counter@add(42) > 0 { give counter.value }
    give 0
}
```

`exclusive flow` makes the receiver mutable for the method call. The receiver
is implicit, so it is removed from the explicit parameter list. Keep the same
ownership and evaluation behavior when making this change; `view` and `edit`
are checked loans, not textual aliases for arbitrary references.

## Types, variants, and iteration

Use `shape` for product data and `choice` for tagged alternatives. Preserve
variant payloads and every branch when migrating a `match` to `choose`:

```ele
choice Outcome of[T] { Good(T), Failed(Text) }

flow value(result: Outcome of[Int]) => Int {
    choose result {
        Outcome.Good(n): { give n },
        Outcome.Failed(_): { give 0 },
    }
}
```

Convert loop syntax according to the original range semantics. For example,
`for i in 0..n` becomes `each i among 0..n`; keep inclusive ranges (`..=`),
loop exits, and mutations intact. Replace angle-bracket generic applications
with `of[...]` in declarations, annotations, and calls, including nested types.

## Common migration errors

- Replacing every `.` with `@` breaks field access. Change only method calls.
- Replacing `let` with `hold` is wrong when the binding is reassigned; use
  `change` for mutable bindings.
- Rewriting `&mut T` as `edit T` requires checking the caller's exclusive-loan
  behavior and the callee's parameter use.
- Renaming an enum to a `choice` does not justify dropping variants or match
  arms. Preserve exhaustiveness and payload types.
- Converting a `for` loop must preserve whether its upper bound is inclusive.
- A parser accepting a v1 spelling during bootstrap does not make that spelling
  canonical or prove that every compiler generation supports the v2 feature.

## Validation and current limits

For each migrated file, run `ele check` (or the repository's equivalent), run
its program when applicable, and retain the original positive and negative
expectations. The `examples/` and `ejemplos/` trees have a v2-only ratchet;
`compiler-l/src` has a decreasing legacy-syntax baseline to track the ongoing
self-hosted source migration.

The Rust Stage 0 frontend accepts the documented v2 surface alongside legacy
aliases during bootstrap. Stage 1 has a narrower supported subset; the current
status, including generic and borrow limitations, is recorded in
[`ELE_SYNTAX_V2.md`](ELE_SYNTAX_V2.md). Do not claim a feature works in Stage 1,
Gen2, or Gen3 until that generation has compiled and exercised it. The
standalone self-hosted parser's grammar is still legacy and is being migrated
incrementally with its source modules.
