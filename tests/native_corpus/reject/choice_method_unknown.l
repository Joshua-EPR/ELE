choice Estado {
    Pendiente,
    Completado,
}

extend Estado {
    flow codigo() => Int {
        give 1
    }
}

flow main() {
    hold e = Estado.Pendiente
    print(e@desconocido())
}
