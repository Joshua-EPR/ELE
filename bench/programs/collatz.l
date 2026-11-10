// Branch-heavy integer workload.
fn pasos(n: Int) -> Int {
    var x = n
    var p = 0
    while x != 1 {
        if x % 2 == 0 { x = x / 2 } else { x = 3 * x + 1 }
        p += 1
    }
    return p
}
fn main() {
    var mejor = 0
    var arg = 0
    for n in 1..1000000 {
        let p = pasos(n)
        if p > mejor {
            mejor = p
            arg = n
        }
    }
    print(arg)
    print(mejor)
}
