// fact(21) does not fit in Int: the checked multiplication deep inside the
// recursion exits with status 125.
flow fact(n: Int) => Int {
    when n <= 1 { give 1 }
    give n * fact(n - 1)
}

flow main() => Int {
    print(fact(20))
    print(fact(21))
    give 0
}
