// Owned branch values move into a single result and are dropped by its caller.
flow make(n: Int) => Text {
    give choose n {
        0: "cero",
        _: "otro",
    }
}

flow main() {
    print(make(0))
    print(make(1))
}
