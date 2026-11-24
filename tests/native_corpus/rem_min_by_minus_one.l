// Int.MIN % -1 is checked like Int.MIN / -1: status 125.
flow rem(a: Int, b: Int) => Int {
    give a % b
}

flow main() => Int {
    hold min = -9223372036854775807 - 1
    print(rem(min, 3))
    print(rem(min, -1))
    give 0
}
