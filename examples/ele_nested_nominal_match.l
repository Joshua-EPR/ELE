// Regression #3: distinct nominal enums reuse variant names safely.
// A nested choose must lower both discriminants and both primitive
// payload projections without mixing First.Full and Second.Full.
choice First {
    Empty,
    Full(Int),
}

choice Second {
    Empty,
    Full(Bool),
}

flow main() => Int {
    hold outer = First@Full(40)
    choose outer {
        First.Empty: { give 1 },
        First.Full(x): {
            hold inner = Second@Full(true)
            choose inner {
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
