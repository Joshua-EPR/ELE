flow doble(n: Int) => Int = n * 2
flow mensaje(nombre: Text, edad: Int) => Text {
    hold resultado = "Hola {nombre}, edad: {edad}; doble: {doble(edad)}"
    give resultado
}
flow main() {
    hold texto = mensaje("Ana", 25)
    print(texto)
    print("Operación: {10 + 20}; llaves: {{valor}}; Bool: {true}")
}
