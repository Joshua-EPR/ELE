// Iteration and sum: build 1 000 000 elements once, then 20 each passes (ELE v2).
flow sumar(datos: view List of[Int]) => Int {
    change total = 0
    each x among datos {
        total += x
    }
    give total
}

flow main() {
    change datos: List of[Int] = List[]
    datos@reserve(1000000)
    change i = 0
    during i < 1000000 {
        datos@push(i % 1000)
        i += 1
    }
    change total = 0
    change pasada = 0
    during pasada < 20 {
        total += sumar(view datos)
        pasada += 1
    }
    print(total)
}
