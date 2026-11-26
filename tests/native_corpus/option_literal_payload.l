// A literal inside Some(..) tests the payload; Some(_) catches the rest.
flow buscar(n: Int) => Int? {
    when n > 0 { give Some(n * 10) }
    give None
}

flow describir(n: Int) => Text {
    hold nota = "n"
    give choose buscar(n) {
        Some(30): "treinta",
        Some(-5): "menos",
        Some(_): "otro",
        None: "nada",
    }
}

flow main() {
    print(describir(3))
    print(describir(4))
    print(describir(0))
    choose buscar(3) {
        Some(30): print("literal"),
        Some(v): print(v),
        None: print("none"),
    }
}
