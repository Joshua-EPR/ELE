// Remainder by zero exits with status 125.
flow rem(a: Int, b: Int) => Int {
    give a % b
}

flow main() => Int {
    print(rem(10, 4))
    print(rem(10, 0))
    give 0
}
