// Cost of a full task life cycle: spawn, scheduling, one suspension, wake,
// resume, result and release (1 000 000 tasks, one at a time).
async fn paso(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn main() {
    var suma = 0
    var i = 0
    while i < 1000000 {
        let t = spawn paso(i)
        let v = await t
        suma += v
        i += 1
    }
    print(suma)
}
