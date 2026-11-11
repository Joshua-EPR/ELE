// Movimientos de shape: recursión que devuelve agregados, movimiento parcial
// de campos (cruzar), agregados junto a Text y edit, choice con payload Bool.
shape Estado {
    paso: Int
    total: Int
    par: Bool
}

shape Par {
    a: Estado
    b: Estado
}

choice Bandera {
    Nada,
    Marca(Bool),
}

flow avanzar(e: Estado, k: Int) => Estado {
    give Estado(paso: e.paso + 1, total: e.total + k, par: !e.par)
}

flow repetir(e: Estado, n: Int) => Estado {
    when n == 0 {
        give e
    }
    give repetir(avanzar(e, n), n - 1)
}

flow cruzar(p: Par) => Par {
    give Par(a: p.b, b: p.a)
}

flow etiqueta(nombre: Text, e: Estado, sufijo: Text) => Int {
    print("{nombre}{sufijo}")
    give e.total
}

flow sumar_en(destino: edit Int, e: Estado) => Estado {
    destino = destino + e.total
    give e
}

flow bandera(e: view Estado) => Bandera {
    when e.par {
        give Bandera.Marca(e.total > 10)
    }
    give Bandera.Nada
}

flow leer(b: Bandera) => Int {
    choose b {
        Bandera.Nada: { give 0 },
        Bandera.Marca(v): {
            when v { give 2 }
            give 1
        },
    }
}

flow main() {
    hold e0 = Estado(paso: 0, total: 0, par: true)
    hold e1 = avanzar(e0, 1)
    hold e2 = avanzar(e1, 2)
    hold e = avanzar(e2, 3)
    print(e.paso)
    print(e.total)
    print(e.par)
    hold r = repetir(Estado(paso: 0, total: 0, par: false), 10)
    print(r.total)
    print(r.paso)
    hold p = cruzar(Par(a: r, b: e))
    print(p.a.total)
    print(p.b.total)
    print(etiqueta("total=", p.a, "!"))
    change acumulado = 1
    hold q = sumar_en(edit acumulado, p.b)
    print(acumulado)
    print(leer(bandera(view q)))
    hold z = Estado(paso: 1, total: 20, par: true)
    print(leer(bandera(view z)))
    print(leer(bandera(view z)) + z.total)
}
