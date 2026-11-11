shape Contador {
    valor: Int = 0
}

extend Contador {
    exclusive flow incrementar() {
        this.valor += 1
    }

    flow obtener() => Int {
        give this.valor
    }
}

flow main() {
    change contador = Contador()

    contador@incrementar()
    contador@incrementar()

    print("Valor: {contador@obtener()}")
}
