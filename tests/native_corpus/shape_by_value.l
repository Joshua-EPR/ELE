// Shapes passed and returned by value, threaded through recursion, and a
// partial move of fields into a new shape.
shape State {
    step: Int
    total: Int
    even: Bool
}

shape Pair {
    a: State
    b: State
}

flow advance(s: State, k: Int) => State {
    give State(step: s.step + 1, total: s.total + k, even: !s.even)
}

flow repeatAdvance(s: State, n: Int) => State {
    when n == 0 { give s }
    give repeatAdvance(advance(s, n), n - 1)
}

flow swap(p: Pair) => Pair {
    give Pair(a: p.b, b: p.a)
}

flow main() {
    hold s0 = State(step: 0, total: 0, even: true)
    hold s1 = advance(s0, 5)
    print("{s1.step} {s1.total} {s1.even}")
    hold r = repeatAdvance(State(step: 0, total: 0, even: false), 10)
    print("{r.step} {r.total} {r.even}")
    hold p = swap(Pair(a: r, b: s1))
    print(p.a.total)
    print(p.b.total)
}
