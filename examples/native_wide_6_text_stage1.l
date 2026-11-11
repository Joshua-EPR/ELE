// Seis campos; el backend debe mover y liberar sus recursos Text.
shape Ficha {
    codigo: Int
    nombre: Text
    nivel: Int
    activa: Bool
    etiqueta: Text
    lote: Int
}

flow crear(codigo: Int) => Ficha {
    give Ficha(codigo: codigo, nombre: "Ana{codigo}", nivel: 2, activa: true,
        etiqueta: "caja{codigo}", lote: 9)
}

flow main() {
    hold ficha = crear(7)
    print(ficha.codigo)
    print(ficha.nombre)
    print(ficha.activa)
    print(ficha.etiqueta)
    print(ficha.lote)
}
