// L0005: a Window live on one incoming path cannot be replaced.
flow main() => Int {
    hold first = "first"
    hold second = "second"
    change w = windowOpen(first, 200, 100)
    when processArgCount() > 0 {
        windowClose(w)
    }
    w = windowOpen(second, 200, 100)
    windowClose(w)
    give 0
}
