// A choice used as a state machine driven by a loop.
choice Light {
    Red,
    Green(Int),
    Yellow,
}

flow next(l: Light) => Light {
    choose l {
        Light.Red: { give Light.Green(3) },
        Light.Green(left): {
            when left > 1 { give Light.Green(left - 1) }
            give Light.Yellow
        },
        Light.Yellow: { give Light.Red },
    }
    give Light.Red
}

flow name(l: view Light) => Text {
    choose l {
        Light.Red: { give "R" },
        Light.Green(left): { give "G{left}" },
        Light.Yellow: { give "Y" },
    }
    give "?"
}

flow main() {
    change l = Light.Red
    change trace = ""
    each i among 0..12 {
        trace = "{trace}{name(view l)} "
        l = next(l)
    }
    print(trace)
}
