// Two choices reusing variant names; nested choose keeps them apart, and
// a wildcard arm covers the rest.
choice First {
    Empty,
    Full(Int),
}

choice Second {
    Empty,
    Full(Bool),
}

flow combine(a: First, b: Second) => Int {
    choose a {
        First.Empty: { give 1 },
        First.Full(x): {
            choose b {
                Second.Empty: { give 2 },
                Second.Full(enabled): {
                    when enabled { give x + 2 }
                    give 3
                },
            }
        },
    }
    give 4
}

flow kind(a: First) => Int {
    choose a {
        First.Full(_): { give 10 },
        _: { give 20 },
    }
    give 30
}

flow main() => Int {
    print(combine(First.Empty, Second.Empty))
    print(combine(First.Full(40), Second.Empty))
    print(combine(First.Full(40), Second.Full(true)))
    print(combine(First.Full(40), Second.Full(false)))
    print(kind(First.Full(1)))
    print(kind(First.Empty))
    give combine(First.Full(5), Second.Full(true))
}
