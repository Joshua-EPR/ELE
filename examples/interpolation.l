fn doble(n: Int) -> Int = n * 2
fn mensaje(nombre: Text, edad: Int) -> Text {
    let resultado = "Hola {nombre}, edad: {edad}; doble: {doble(edad)}"
    return resultado
}
fn main() {
    let texto = mensaje("Ana", 25)
    print(texto)
    print("Operación: {10 + 20}; llaves: {{valor}}; Bool: {true}")
}
