// choice with unit, Int and Bool payloads; choose binds payloads (also
// inside interpolation) and every variant is handled.
choice Figure {
    Empty,
    Square(Int),
    Flag(Bool),
}

flow describe(s: Figure) => Text {
    choose s {
        Figure.Empty: { give "vacio" },
        Figure.Square(side): { give "cuadrado {side * side}" },
        Figure.Flag(on): {
            when on { give "bandera si" }
            give "bandera no"
        },
    }
    give "inalcanzable"
}

flow main() {
    print(describe(Figure.Empty))
    print(describe(Figure.Square(7)))
    print(describe(Figure.Flag(true)))
    print(describe(Figure.Flag(false)))
}
