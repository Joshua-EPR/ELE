// Calling a two-parameter flow with one argument.
flow add(a: Int, b: Int) => Int {
    give a + b
}

flow main() => Int {
    give add(1)
}
