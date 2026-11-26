choice Estado {
    Pendiente,
    Completado,
}

extend Estado {
    exclusive flow marcar() => Int {
        give 1
    }
}

flow main() {
    hold e = Estado.Pendiente
    print(e@marcar())
}
