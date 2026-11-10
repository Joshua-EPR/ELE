// Iteration and sum: build 1 000 000 elements once, then 20 for-each passes.
fn sumar(datos: &[Int]) -> Int {
    var total = 0
    for x in datos {
        total += x
    }
    return total
}
fn main() {
    var datos: List<Int> = List[]
    datos.reserve(1000000)
    var i = 0
    while i < 1000000 {
        datos.push(i % 1000)
        i += 1
    }
    var total = 0
    var pasada = 0
    while pasada < 20 {
        total += sumar(datos)
        pasada += 1
    }
    print(total)
}
