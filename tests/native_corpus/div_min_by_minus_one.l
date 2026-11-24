// Int.MIN / -1 is the one overflowing quotient: status 125.
flow div(a: Int, b: Int) => Int {
    give a / b
}

flow main() => Int {
    hold min = -9223372036854775807 - 1
    print(div(min, -2))
    print(div(min, -1))
    give 0
}
