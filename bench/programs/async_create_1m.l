// Task creation and destruction: 1 000 000 futures built and released
// without ever being polled.
async fn trabajo(n: Int) -> Int {
    return n
}

async fn main() {
    var i = 0
    while i < 1000000 {
        let pendiente = trabajo(i)
        i += 1
    }
    print(i)
}
