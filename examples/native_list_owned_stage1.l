// Listas cuyos elementos poseen memoria: Text (literales y del heap),
// shapes con Text y listas anidadas. Los elementos se liberan con la lista.
shape Ficha {
    clave: Text
    peso: Int
}

shape Mesa {
    fichas: List of[Ficha]
    notas: List of[Text]
    filas: List of[List of[Int]]
}

flow ficha(n: Int) => Ficha {
    give Ficha(clave: "k{n}", peso: n)
}

flow agregar(m: edit Mesa, n: Int) {
    m.fichas@push(ficha(n))
    m.notas@push("nota{n * 3}")
    m.filas@push(List[n, n + 1, n + 2])
}

flow pesos(m: view Mesa) => Int {
    change total = 0
    change i = 0
    during i < m.fichas.length {
        total += m.fichas[i].peso
        i += 1
    }
    give total
}

flow nombres(n: Int) => List of[Text] {
    change out: List of[Text] = List["cero"]
    change i = 1
    during i < n {
        out@push("n{i}")
        i += 1
    }
    give out
}

flow main() {
    change f: List of[Ficha] = List[]
    change t: List of[Text] = List[]
    change r: List of[List of[Int]] = List[]
    change m = Mesa(fichas: f, notas: t, filas: r)
    change i = 0
    during i < 300 {
        agregar(edit m, i)
        i += 1
    }
    print(m.fichas.length)
    print(pesos(view m))
    print(m.fichas[299].clave)
    print(m.notas[150])
    print(m.notas[7].byteLength)
    print(m.filas[10][2])
    m.fichas[5].peso = 1000
    print(pesos(view m))
    hold ns = nombres(1200)
    print(ns.length)
    print(ns[0])
    print(ns[1199])
    change j = 0
    during j < 20 {
        hold tmp = nombres(j + 1)
        print(tmp[j].byteLength)
        j += 1
    }
}
