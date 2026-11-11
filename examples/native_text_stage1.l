// Text propio en el backend nativo escrito en ELE: literales, interpolación,
// crecimiento del buffer, paso por valor, retorno y liberación determinista.
flow repetir(base: Text, veces: Int, a: Int, b: Int, c: Bool) => Text {
    change acumulado = "inicio"
    change i = 0
    during i < veces {
        hold siguiente = "{acumulado}|{base}:{i}:{a + b}:{c}"
        acumulado = siguiente
        i += 1
    }
    give acumulado
}

flow medir(n: Int) => Int {
    hold texto = repetir("0123456789abcdefghijklmnopqrstuvwxyz", n, 0 - 5, 2, false)
    print(texto)
    give n
}

flow main() {
    print("Hola, José 👋")
    print(repetir("x", 3, 1, 2, true))
    hold n = medir(400)
    print(n)
}
