// Text dentro de shape en el backend nativo escrito en ELE: construcción,
// lectura prestada, reemplazo con edit, movimiento y liberación por campo.
shape Persona {
    nombre: Text
    edad: Int
}

shape Grupo {
    jefe: Persona
    lema: Text
}

flow crear(n: Text, e: Int) => Persona {
    give Persona(nombre: n, edad: e)
}

flow saludo(p: view Persona) => Text {
    give "Hola {p.nombre} ({p.edad})"
}

flow largo(p: view Persona) => Int {
    give p.nombre.byteLength
}

flow tomar(p: Persona) => Text {
    give p.nombre
}

flow renombrar(p: edit Persona, n: Text) {
    p.nombre = n
}

flow main() {
    change ana = crear("Ana", 30)
    print(saludo(view ana))
    renombrar(edit ana, "Ana María")
    print(largo(view ana))
    print(ana.nombre)
    hold g = Grupo(jefe: crear("Luis", 40), lema: "unidos")
    print(g.jefe.nombre)
    print(g.lema)
    hold nombre = tomar(ana)
    print(nombre)
}
