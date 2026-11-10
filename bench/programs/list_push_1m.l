// Insertion: 1 000 000 push into an empty List<Int> (geometric growth).
fn main() {
    var datos: List<Int> = List[]
    var i = 0
    while i < 1000000 {
        datos.push(i)
        i += 1
    }
    print(datos.length)
    print(datos.capacity)
}
