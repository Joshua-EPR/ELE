// Indexed (bounds-checked) reads: build 1 000 000 elements, 20 passes of datos[i].
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
        var j = 0
        while j < datos.length {
            total += datos[j]
            j += 1
        }
        pasada += 1
    }
    print(total)
}
