// Fields with a default may be omitted from the constructor; fields given
// explicitly override it. Defaults are constants (literals and fixed values).
fixed LIMITE = 10

shape Contador {
    valor: Int = 0
    paso: Int = 1
}

shape Usuario {
    nombre: Text
    edad: Int = 18
    activo: Bool = true
    rol: Text = "invitado"
    tope: Int = LIMITE * 2
}

flow mostrar(u: view Usuario) {
    print("{u.nombre} {u.edad} {u.activo} {u.rol} {u.tope}")
}

flow main() {
    change c = Contador()
    c.valor += c.paso
    print("{c.valor} {c.paso}")

    hold c2 = Contador(paso: 5)
    print("{c2.valor} {c2.paso}")
    hold c3 = Contador(valor: 7, paso: 2)
    print("{c3.valor} {c3.paso}")

    hold ana = Usuario(nombre: "Ana")
    mostrar(ana)
    hold bob = Usuario(rol: "admin", nombre: "Bob", activo: false)
    mostrar(bob)
    hold eva = Usuario(nombre: "Eva", edad: 40, rol: "jefa", tope: 1)
    mostrar(eva)

    // A local with the same name as the fixed value does not capture it.
    hold LIMITE = 3
    hold dos = Usuario(nombre: "Dos")
    print("{LIMITE} {dos.tope}")

    // Owned Text defaults are created and released once per construction.
    change i = 0
    during i < 3 {
        hold u = Usuario(nombre: "u{i}")
        print("{u.nombre} {u.rol}")
        i += 1
    }
}
