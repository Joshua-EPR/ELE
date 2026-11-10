// Cost of interleaving: a chain of 100 000 tasks alive at the same time, each
// one suspended waiting for the next (round-robin over the ready queue).
async fn hoja(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn rama(n: Int) -> Int {
    if n <= 0 {
        return 0
    }
    let hijo = spawn rama(n - 1)
    let mio = spawn hoja(n)
    await yieldNow()
    let a = await hijo
    let b = await mio
    return a + b
}

async fn main() {
    let r = spawn rama(100000)
    let total = await r
    print(total)
}
