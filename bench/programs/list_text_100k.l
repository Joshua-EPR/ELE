// Owned elements: 100 000 heap Text values pushed, read, then released.
fn main() {
    var nombres: List<Text> = List[]
    var i = 0
    while i < 100000 {
        nombres.push("nombre {i}")
        i += 1
    }
    var cuenta = 0
    for n in nombres {
        cuenta += 1
    }
    print(cuenta)
    print(nombres[99999])
}
