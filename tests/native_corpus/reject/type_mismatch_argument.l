// A Text argument for an Int parameter.
flow twice(n: Int) => Int {
    give n * 2
}

flow main() => Int {
    give twice("dos")
}
