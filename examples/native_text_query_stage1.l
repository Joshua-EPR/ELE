// byteLength y byteAt sobre Text propio, literal y prestado con view:
// cuenta bytes, compara Text byte a byte y recorre UTF-8 multibyte.
shape Punto {
    x: Int
    y: Int
}

flow sumar(p: view Punto) => Int {
    give p.x + p.y
}

flow mover(p: edit Punto, d: Int) {
    p.x = p.x + d
}

flow incrementar(n: edit Int) {
    n = n + 1
}

flow contar(t: view Text, b: Int) => Int {
    change i = 0
    change total = 0
    during i < t.byteLength {
        when t@byteAt(i) == b {
            total += 1
        }
        i += 1
    }
    give total
}

flow iguales(a: view Text, b: view Text) => Bool {
    when a.byteLength != b.byteLength {
        give false
    }
    change i = 0
    during i < a.byteLength {
        when a@byteAt(i) != b@byteAt(i) {
            give false
        }
        i += 1
    }
    give true
}

// Cuenta puntos de código: un byte de continuación UTF-8 es 10xxxxxx.
flow caracteres(t: view Text) => Int {
    change i = 0
    change total = 0
    during i < t.byteLength {
        hold b = t@byteAt(i)
        when b < 128 || b >= 192 {
            total += 1
        }
        i += 1
    }
    give total
}

flow main() {
    change p = Punto(x: 1, y: 2)
    mover(edit p, 10)
    print(sumar(view p))
    change n = 5
    incrementar(edit n)
    incrementar(edit n)
    print(n)
    hold t = "banana"
    print(contar(view t, 97))
    print(t.byteLength)
    hold u = "ban{"ana"}"
    print(iguales(view t, view u))
    hold v = "bananas"
    print(iguales(view t, view v))
    hold w = "José 👋"
    print(w.byteLength)
    print(caracteres(view w))
}
