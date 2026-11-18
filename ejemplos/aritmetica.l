space hola.main
take std.io.print

flow doble(x: Int) => Int = x * 2

flow main() {
    hold resultado = doble(21)
    print(resultado)
}
