// A choice whose variant owns a Text payload: built from a literal and from
// an interpolated Text, matched, and the payload printed.
choice Message {
    Quiet,
    Code(Int),
    Named(Text),
}

flow describe(m: Message) => Text {
    choose m {
        Message.Quiet: { give "silencio" },
        Message.Code(c): { give "codigo {c}" },
        Message.Named(name): { give "nombre {name}" },
    }
    give "inalcanzable"
}

flow main() {
    print(describe(Message.Quiet))
    print(describe(Message.Code(7)))
    print(describe(Message.Named("ele")))
    hold n = 3
    print(describe(Message.Named("dinamico {n}")))
}
