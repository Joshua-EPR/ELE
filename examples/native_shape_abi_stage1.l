// shape y choice por valor en el backend nativo escrito en ELE: parámetros,
// resultados (por puntero oculto), anidamiento y choice con payload.
shape Punto {
    x: Int
    y: Int
}

shape Caja {
    esquina: Punto
    lleno: Bool
}

choice Forma {
    Vacia,
    Lado(Int),
}

flow crear(x: Int, y: Int) => Punto {
    give Punto(x: x, y: y)
}

flow sumar(p: Punto) => Int {
    give p.x + p.y
}

flow trasladar(p: Punto, d: Int) => Punto {
    give Punto(x: p.x + d, y: p.y + d)
}

flow envolver(p: Punto, lleno: Bool) => Caja {
    give Caja(esquina: p, lleno: lleno)
}

flow forma(n: Int) => Forma {
    when n > 0 {
        give Forma.Lado(n)
    }
    give Forma.Vacia
}

flow area(f: Forma) => Int {
    choose f {
        Forma.Vacia: { give 0 },
        Forma.Lado(l): { give l * l },
    }
}

flow main() {
    hold p = crear(3, 4)
    hold q = trasladar(p, 10)
    print(sumar(q))
    hold c = envolver(crear(1, 2), true)
    print(c.lleno)
    print(c.esquina.y)
    print(area(forma(7)))
    print(area(forma(-1)))
}
