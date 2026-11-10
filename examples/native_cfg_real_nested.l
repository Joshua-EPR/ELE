// End-to-end target: Stage1 source -> ELE-LIR -> ELE-written native backend.
// Both aggregates are drop-free but move-only. This does not exercise heap values.
struct Inner { value: Int, active: Bool }
struct Outer { inner: Inner, extra: Int }

fn main() -> Int {
    let inner = Inner(value: 22, active: true)
    let outer = Outer(inner: inner, extra: 20)
    if outer.inner.active { return outer.inner.value + outer.extra }
    return 0
}
