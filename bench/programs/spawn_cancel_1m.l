// Cost of spawn + cancel: a million tasks are registered in the scheduler and
// destroyed before they ever run (the handle dies at the end of its scope).
async fn paso(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn main() {
    var i = 0
    while i < 1000000 {
        let t = spawn paso(i)
        i += 1
    }
    print(i)
}
