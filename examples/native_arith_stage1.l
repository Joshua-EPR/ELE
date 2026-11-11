// Aritmética entera nativa: división y resto truncados hacia cero, negación
// y not, con valores negativos y los extremos de Int.
flow dividir(a: Int, b: Int) => Int {
    give a / b
}

flow resto(a: Int, b: Int) => Int {
    give a % b
}

flow main() {
    print(dividir(7, 2))
    print(dividir(-7, 2))
    print(dividir(7, -2))
    print(dividir(-7, -2))
    print(resto(7, 3))
    print(resto(-7, 3))
    print(resto(7, -3))
    print(resto(-7, -3))
    hold minimo = -9223372036854775807 - 1
    print(dividir(minimo, 1))
    print(resto(minimo, -1 + 2))
    print(dividir(9223372036854775807, -1))
    hold x = 5
    print(-x)
    print(-(-x))
    hold verdad = true
    print(!verdad)
    print(!(x > 3))
    print(x / 2 * 2 + x % 2 == x)
}
