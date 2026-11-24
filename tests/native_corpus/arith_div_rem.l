// Integer division and remainder truncate toward zero; the identity
// (a / b) * b + a % b == a holds for every sign combination.
flow check(a: Int, b: Int) {
    hold q = a / b
    hold r = a % b
    print("{a} / {b} = {q} rem {r} ok={q * b + r == a}")
}

flow main() {
    check(7, 2)
    check(-7, 2)
    check(7, -2)
    check(-7, -2)
    check(0, 5)
    check(5, 7)
    hold min = -9223372036854775807 - 1
    check(min, 1)
    check(min, 2)
    check(9223372036854775807, -1)
}
