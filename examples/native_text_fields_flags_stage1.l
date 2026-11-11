// Movimiento condicional de un campo Text: la liberación del campo usa una
// bandera de drop en la unión de las ramas.
shape Caja {
    texto: Text
    n: Int
}

flow abrir(c: Caja, tomar: Bool) => Int {
    when tomar {
        hold t = c.texto
        print(t)
        give 1
    }
    give c.n
}

flow quizas(c: Caja, tomar: Bool) => Int {
    change r = c.n
    when tomar {
        hold t = c.texto
        print(t)
        r = r + 100
    }
    give r
}

flow main() {
    print(abrir(Caja(texto: "uno {1}", n: 5), true))
    print(abrir(Caja(texto: "dos {2}", n: 6), false))
    print(quizas(Caja(texto: "tres {3}", n: 7), true))
    print(quizas(Caja(texto: "cuatro {4}", n: 8), false))
}
