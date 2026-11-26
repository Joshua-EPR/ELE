choice Estado {
    Pendiente,
    Completado,
}

extend Estado {
    flow desde(base: Int) => Int {
        give base
    }
}

flow main() {
    hold e = Estado.Pendiente
    print(e@desde(1, 2))
}
