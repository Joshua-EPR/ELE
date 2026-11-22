// L0005: replacing a live Window must not discard its OS resources.
flow main() => Int {
    hold first = "first"
    hold second = "second"
    change w = windowOpen(first, 200, 100)
    w = windowOpen(second, 200, 100)
    windowClose(w)
    give 0
}
