const SALUDO: Text = "Hola, José 👋"

fn identidad(texto: Text) -> Text = texto

fn main() {
    let mensaje: Text = identidad(SALUDO)
    print(mensaje)
    print(mensaje)
    let transferido = mensaje
    print(transferido)
    print("Unicode: \u{1F680}; llaves: {{L}}")
}
