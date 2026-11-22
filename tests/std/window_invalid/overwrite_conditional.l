// L0005: one conditional replacement is enough to leak a Window.
flow main() => Int {
    hold first = "first"
    hold second = "second"
    change w = windowOpen(first, 200, 100)
    when processArgCount() > 0 {
        w = windowOpen(second, 200, 100)
    }
    windowClose(w)
    give 0
}
