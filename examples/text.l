fixed SALUDO: Text = "Hola, José 👋"

flow identidad(texto: Text) => Text = texto

flow main() {
    hold mensaje: Text = identidad(SALUDO)
    print(mensaje)
    print(mensaje)
    hold transferido = mensaje
    print(transferido)
    print("Unicode: \u{1F680}; llaves: {{L}}")
}
