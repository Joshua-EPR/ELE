// !, && and || including short-circuit evaluation: the right operand
// would divide by zero (status 125) if it were evaluated.
flow boom(d: Int) => Bool {
    give 10 / d > 0
}

flow main() => Int {
    hold zero = 0
    hold t = true
    hold f = false
    print(!t)
    print(t && f)
    print(t || f)
    print(!(t && f) == (!t || !f))
    print(f && boom(zero))
    print(t || boom(zero))
    print(t && boom(5))
    give 0
}
