shape Punto {
    x: Int
    y: Int
}

shape Usuario {
    nombre: Text
    edad: Int
    activo: Bool = true
    origen: Punto
}

extend Punto {
    direct flow origen() => Punto = Punto(x: 0, y: 0)
    flow suma() = this.x + this.y
    exclusive flow mover(dx: Int, dy: Int) {
        this.x += dx
        this.y += dy
    }
}

extend Usuario {
    direct flow invitado() => Usuario {
        give Usuario(nombre: "Invitado", edad: 0, origen: Punto(x: 1, y: 2))
    }
    flow saludar() {
        print("Hola {this.nombre}")
    }
    exclusive flow cumplirAnios() {
        this.edad += 1
    }
    flow presentar() => Text = "{this.nombre} ({this.edad}) activo={this.activo}"
}

flow crear(nombre: Text) => Usuario = Usuario(edad: 30, nombre: nombre, origen: Punto@origen())

flow main() {
    change ana = crear("Ana")
    ana@saludar()
    ana@cumplirAnios()
    print(ana@presentar())
    ana.origen@mover(3, 4)
    print("origen: {ana.origen.x},{ana.origen.y} suma={ana.origen@suma()}")
    ana.activo = false
    print(ana@presentar())

    hold invitado = Usuario@invitado()
    print(invitado@presentar())
    print(Punto@origen()@suma())

    change total = 0
    each i among 1..=10 {
        total += i
    }
    each i among 0..3 {
        when i == 1 {
            proceed
        }
        print(i)
    }
    print("total: {total}")
}
