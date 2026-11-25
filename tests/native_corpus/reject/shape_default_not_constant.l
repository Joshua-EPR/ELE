// A default is a constant expression: calls and variables are not allowed.
flow base() => Int {
    give 4
}

shape Punto {
    x: Int = base()
}

flow main() {
    hold p = Punto(x: 1)
    print(p.x)
}
