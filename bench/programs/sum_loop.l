// Tight loop with checked arithmetic, division and remainder (ELE v2).
flow main() {
    change total = 0
    each i among 1..=200000000 {
        total += i % 7 + i / 1000000
    }
    print(total)
}
