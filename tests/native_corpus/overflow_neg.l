// Negating Int.MIN overflows: status 125.
flow neg(a: Int) => Int {
    give -a
}

flow main() => Int {
    hold min = -9223372036854775807 - 1
    print(neg(-9223372036854775807))
    hold boom = neg(min)
    print(boom)
    give 0
}
