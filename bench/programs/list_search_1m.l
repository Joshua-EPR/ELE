// Linear search: 20 lookups of values near the end of 1 000 000 elements.
fn buscar(datos: &[Int], objetivo: Int) -> Int {
    var i = 0
    while i < datos.length {
        if datos[i] == objetivo {
            return i
        }
        i += 1
    }
    return -1
}
fn main() {
    var datos: List<Int> = List[]
    var i = 0
    while i < 1000000 {
        datos.push(i * 3)
        i += 1
    }
    var encontrados = 0
    var k = 0
    while k < 20 {
        if buscar(datos, (999980 + k) * 3) >= 0 {
            encontrados += 1
        }
        k += 1
    }
    print(encontrados)
}
