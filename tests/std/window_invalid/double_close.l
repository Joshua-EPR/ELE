// L0005: windowClose consumes the Window; closing again is use-after-move.
flow main() => Int {
    hold title = "twice"
    hold w = windowOpen(title, 200, 100)
    windowClose(w)
    give windowClose(w)
}
