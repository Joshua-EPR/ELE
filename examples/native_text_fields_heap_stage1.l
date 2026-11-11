// Text propios (heap) en campos de shape anidados: interpolación, reemplazo
// repetido con edit, movimiento por valor y 50 fichas creadas y liberadas.
shape Ficha {
    clave: Text
    valor: Text
    peso: Int
}

shape Par {
    izquierda: Ficha
    derecha: Ficha
}

flow ficha(n: Int) => Ficha {
    give Ficha(clave: "k{n}", valor: "v{n * 10}", peso: n)
}

flow describir(f: view Ficha) => Text {
    give "{f.clave}={f.valor}/{f.peso}"
}

flow cambiar(f: edit Ficha, n: Int) {
    f.valor = "nuevo{n}"
    f.peso = n
}

flow tomar_clave(f: Ficha) => Text {
    give f.clave
}

flow ancho(p: view Par) => Int {
    give p.izquierda.clave.byteLength + p.derecha.valor.byteLength
}

flow juntar(a: Ficha, b: Ficha) => Par {
    give Par(izquierda: a, derecha: b)
}

flow main() {
    change uno = ficha(1)
    print(describir(view uno))
    cambiar(edit uno, 7)
    cambiar(edit uno, 8)
    print(describir(view uno))
    hold par = juntar(uno, ficha(2))
    print(ancho(view par))
    print(par.derecha.valor)
    hold clave = tomar_clave(ficha(3))
    print(clave)
    change i = 0
    during i < 50 {
        hold f = ficha(i)
        print(f.valor.byteAt(0))
        i += 1
    }
}
