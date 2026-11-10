struct Punto {
    x: Int
    y: Int
}

struct Usuario {
    nombre: Text
    edad: Int
    activo: Bool = true
    origen: Punto
}

impl Punto {
    static fn origen() -> Punto = Punto(x: 0, y: 0)
    fn suma() = self.x + self.y
    mut fn mover(dx: Int, dy: Int) {
        self.x += dx
        self.y += dy
    }
}

impl Usuario {
    static fn invitado() -> Usuario {
        return Usuario(nombre: "Invitado", edad: 0, origen: Punto(x: 1, y: 2))
    }
    fn saludar() {
        print("Hola {self.nombre}")
    }
    mut fn cumplirAnios() {
        self.edad += 1
    }
    fn presentar() -> Text = "{self.nombre} ({self.edad}) activo={self.activo}"
}

fn crear(nombre: Text) -> Usuario = Usuario(edad: 30, nombre: nombre, origen: Punto.origen())

fn main() {
    var ana = crear("Ana")
    ana.saludar()
    ana.cumplirAnios()
    print(ana.presentar())
    ana.origen.mover(3, 4)
    print("origen: {ana.origen.x},{ana.origen.y} suma={ana.origen.suma()}")
    ana.activo = false
    print(ana.presentar())

    let invitado = Usuario.invitado()
    print(invitado.presentar())
    print(Punto.origen().suma())

    var total = 0
    for i in 1..=10 {
        total += i
    }
    for i in 0..3 {
        if i == 1 {
            continue
        }
        print(i)
    }
    print("total: {total}")
}
