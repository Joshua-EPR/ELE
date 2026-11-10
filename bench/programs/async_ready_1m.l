// Awaiting futures that are ready on the first poll: creation, one poll and
// release, 1 000 000 times.
async fn trabajo(n: Int) -> Int {
    return n + 1
}

async fn main() {
    var suma = 0
    var i = 0
    while i < 1000000 {
        let v = await trabajo(i)
        suma += v
        i += 1
    }
    print(suma)
}
