// Referencias view/edit y consultas de Text en el backend nativo escrito en ELE:
// paso por referencia de Int, Bool, Text, shape anidado y choice; escritura
// mediante edit (también reenviada), byteLength y byteAt con límites.
shape Interior {
    activo: Bool
    valor: Int
}

shape Exterior {
    id: Int
    dentro: Interior
}

choice Signo {
    Cero,
    Pos(Int),
}

flow alternar(e: edit Exterior) {
    e.dentro.activo = !e.dentro.activo
    e.dentro.valor = e.dentro.valor * 2
}

flow pasar(e: edit Exterior) {
    alternar(edit e)
    alternar(edit e)
    alternar(edit e)
}

flow activo(e: view Exterior) => Bool {
    give e.dentro.activo
}

flow mostrar(t: view Text) {
    print(t)
}

flow tamano(s: view Signo) => Int {
    choose s {
        Signo.Cero: { give 0 },
        Signo.Pos(v): { give v },
    }
}

flow suma(a: view Int, b: view Int) => Int {
    give a + b
}

flow main() {
    change e = Exterior(id: 7, dentro: Interior(activo: false, valor: 3))
    pasar(edit e)
    print(activo(view e))
    print(e.dentro.valor)
    hold saludo = "hola ñandú"
    mostrar(view saludo)
    print(saludo.byteLength)
    print(saludo.byteAt(5))
    hold s = Signo.Pos(41)
    print(tamano(view s) + 1)
    hold x = 20
    print(suma(view x, view x))
}
