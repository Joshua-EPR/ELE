shape Contador {
    valor: Int = 0
}

extend Contador {
    exclusive flow incrementar() {
        this.valor += 1
    }
}

flow main() {
    hold contador = Contador()
    contador@incrementar()
}
