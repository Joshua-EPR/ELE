// Real suspensions: each iteration stops the task, notifies it and resumes it
// (1 000 000 suspend/resume cycles through the executor).
async fn paso(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn main() {
    var suma = 0
    var i = 0
    while i < 1000000 {
        let v = await paso(i)
        suma += v
        i += 1
    }
    print(suma)
}
