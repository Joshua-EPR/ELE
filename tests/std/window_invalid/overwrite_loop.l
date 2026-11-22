// L0005: replacing a Window in a loop leaks the previous iteration's handle.
flow main() => Int {
    hold first = "first"
    hold second = "second"
    change w = windowOpen(first, 200, 100)
    change n = 0
    during n < 1 {
        w = windowOpen(second, 200, 100)
        n += 1
    }
    windowClose(w)
    give 0
}
