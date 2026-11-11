// Préstamos locales y each sobre elementos propietarios en el backend ELE:
// la variable del bucle es una referencia al elemento; view y edit locales
// sobre variables, campos y elementos de listas.
shape Ficha {
    clave: Text
    peso: Int
}

shape Mesa {
    fichas: List of[Ficha]
    notas: List of[Text]
    total: Int
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

flow largo(ts: view List of[Text]) => Int {
    change n = 0
    each t among ts {
        n += t.byteLength
    }
    give n
}

flow pesos(m: view Mesa) => Int {
    change n = 0
    each f among m.fichas {
        n += f.peso + f.clave.byteLength
    }
    give n
}

flow engordar(m: edit Mesa, i: Int, extra: Int) {
    hold f = edit m.fichas[i]
    f.peso += extra
    m.total += extra
}

flow buscar(ts: view List of[Text], largo: Int) => Int {
    change i = 0
    each t among ts {
        when t.byteLength == largo { give i }
        i += 1
    }
    give -1
}

flow main() {
    change ts = nombres(12)
    each t among ts {
        print(t)
    }
    print(largo(view ts))
    ts@push("fin")
    print(buscar(view ts, 3))
    print(buscar(view ts, 9))
    change f: List of[Ficha] = List[]
    change n: List of[Text] = List[]
    change m = Mesa(fichas: f, notas: n, total: 0)
    change i = 0
    during i < 50 {
        m.fichas@push(Ficha(clave: "k{i}", peso: i))
        m.notas@push("nota{i}")
        i += 1
    }
    print(pesos(view m))
    engordar(edit m, 7, 100)
    engordar(edit m, 7, 1)
    print(m.fichas[7].peso)
    print(m.total)
    hold primera = view m.fichas[0]
    print(primera.clave)
    print(primera.peso + m.fichas.length)
    hold x = view m.total
    print(x + 1)
    each nota among m.notas {
        when nota.byteLength > 5 { leave }
        print(nota)
    }
    each k among List[3, 2, 1] {
        print(k)
    }
    each t among nombres(3) {
        print(t.byteLength)
    }
}
