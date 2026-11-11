// Salida real desde el backend nativo escrito en ELE: `print` de Int y Bool
// y funciones sin valor de retorno, en sintaxis canónica ELE.
flow mostrar(valor: Int) {
    print(valor)
}

flow resta(a: Int, b: Int) => Int {
    give a - b
}

flow factorial(n: Int) => Int {
    when n <= 1 {
        give 1
    }
    give n * factorial(n - 1)
}

flow main() {
    mostrar(0)
    mostrar(resta(0, 7))
    print(9223372036854775807)
    hold minimo = resta(0 - 9223372036854775807, 1)
    print(minimo)
    print(1 < 2)
    print(2 < 1)
    change total = 0
    change i = 1
    during i <= 5 {
        total += i
        i += 1
    }
    print(total)
    print(factorial(20))
}
