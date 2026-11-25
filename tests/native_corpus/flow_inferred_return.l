// `flow f(..) = expr` without `=> Type` returns the type of the expression.
shape Punto {
    x: Int
    y: Int
}

extend Punto {
    flow suma() = this.x + this.y
    flow esOrigen() = this.x == 0 && this.y == 0
    flow etiqueta() = "({this.x}, {this.y})"
    direct flow origen() = Punto(x: 0, y: 0)
    flow doblado() = Punto(x: this.x * 2, y: this.y * 2)
    flow total() = this@suma() + extra(1)
}

flow doble(x: Int) = x * 2
flow triple(x: Int) = doble(x) + x
flow mayor(a: Int, b: Int) = a > b
flow saludo(nombre: Text) = "hola {nombre}"
flow desplazar(p: view Punto, dx: Int) = Punto(x: p.x + dx, y: p.y)
// Calls may precede the callee's declaration.
flow adelantado() = definido(3)
flow definido(n: Int) = n + 100
flow extra(n: Int) = n * 10
// Unit result: the expression is a call returning ().
flow aviso(n: Int) = print("aviso {n}")

flow main() {
    print(doble(21))
    print(triple(5))
    print(mayor(3, 2))
    print(mayor(2, 3))
    print(saludo("Ana"))
    print(adelantado())
    aviso(7)
    hold p = Punto(x: 3, y: 4)
    print(p@suma())
    print(p@esOrigen())
    print(p@etiqueta())
    print(p@total())
    hold o = Punto@origen()
    print(o@esOrigen())
    hold d = p@doblado()
    print(d@suma())
    hold q = desplazar(p, 10)
    print(q@etiqueta())
    print(desplazar(p, 1)@suma())
}
