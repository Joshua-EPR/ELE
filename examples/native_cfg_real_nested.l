// End-to-end target: Stage1 source -> ELE-LIR -> ELE-written native backend.
// Both aggregates are drop-free but move-only. This does not exercise heap values.
shape Inner { value: Int, active: Bool }
shape Outer { inner: Inner, extra: Int }

flow main() => Int {
    hold inner = Inner(value: 22, active: true)
    hold outer = Outer(inner: inner, extra: 20)
    when outer.inner.active { give outer.inner.value + outer.extra }
    give 0
}
