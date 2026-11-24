// Repeated doubling: 2^62 is the last power of two that fits, so the
// 63rd doubling exits with status 125 after the lines for steps 10..60.
flow main() => Int {
    change x = 1
    change steps = 0
    repeat {
        x = x * 2
        steps += 1
        when steps % 10 == 0 {
            print("{steps}: {x}")
        }
    }
    give 0
}
