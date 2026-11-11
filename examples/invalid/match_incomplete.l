choice Estado {
    Pendiente,
    Completado,
    Error(Text),
}

flow mostrar(estado: Estado) {
    choose estado {
        Estado.Pendiente: print("Pendiente"),
        Estado.Error(mensaje): print(mensaje),
    }
}

flow main() {
    mostrar(Estado.Completado)
}
