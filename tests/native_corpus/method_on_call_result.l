// A `view` method called directly on the result of a call.
shape Punto {
    x: Int
    y: Int
}

shape Persona {
    nombre: Text
    edad: Int
}

extend Punto {
    direct flow origen() => Punto = Punto(x: 1, y: 2)
    flow suma() => Int {
        give this.x + this.y
    }
}

extend Persona {
    direct flow invitado() => Persona {
        give Persona(nombre: "Invitado", edad: 7)
    }
    flow presentar() => Text = "{this.nombre} ({this.edad})"
}

flow crear(n: Int) => Persona {
    give Persona(nombre: "p{n}", edad: n)
}

flow main() {
    print(Punto@origen()@suma())
    print(Persona@invitado()@presentar())
    print(crear(3)@presentar())
    hold t = crear(4)@presentar()
    print(t)
}
