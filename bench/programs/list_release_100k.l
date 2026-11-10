// Creation and release: 50 lists of 100 000 elements, each freed at scope end.
fn llenar(n: Int) -> Int {
    var datos: List<Int> = List[]
    var i = 0
    while i < n {
        datos.push(i)
        i += 1
    }
    return datos[n - 1]
}
fn main() {
    var total = 0
    var r = 0
    while r < 50 {
        total += llenar(100000)
        r += 1
    }
    print(total)
}
