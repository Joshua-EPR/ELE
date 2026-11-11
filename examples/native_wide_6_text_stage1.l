// Seis campos; el backend debe mover y liberar sus recursos Text.
shape Ficha {
    codigo: Int
    nombre: Text
    nivel: Int
    activa: Bool
    etiqueta: Text
    lote: Int
}

flow crear() => Ficha {
    give Ficha(codigo: 7, nombre: "Ana", nivel: 2, activa: true,
        etiqueta: "caja", lote: 9)
}

flow main() {
    hold ficha = crear()
    print(ficha.codigo)
    print(ficha.nombre)
    print(ficha.activa)
    print(ficha.etiqueta)
    print(ficha.lote)
}
