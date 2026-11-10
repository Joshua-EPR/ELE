// Tight loop with checked arithmetic, division and remainder.
fn main() {
    var total = 0
    for i in 1..=200000000 {
        total += i % 7 + i / 1000000
    }
    print(total)
}
