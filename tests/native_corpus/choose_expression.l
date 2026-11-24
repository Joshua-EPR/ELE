// choose used as an expression, with Int literal patterns and a wildcard.
flow name(n: Int) => Text {
    give choose n {
        0: "cero",
        1: "uno",
        2: "dos",
        _: "muchos",
    }
}

flow main() {
    each i among 0..4 {
        print(name(i))
    }
    hold b = true
    hold v = choose b {
        true: 10,
        false: 20,
    }
    print(v)
}
