// give with a Bool from a flow declared to give Int.
flow f() => Int {
    give true
}

flow main() => Int {
    give f()
}
