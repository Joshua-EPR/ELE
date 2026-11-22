// L0005: an edit parameter must not discard its live Window referent.
flow replace(w: edit Window) {
    hold title = "second"
    w = windowOpen(title, 200, 100)
}

flow main() => Int {
    hold first = "first"
    change w = windowOpen(first, 200, 100)
    replace(edit w)
    windowClose(w)
    give 0
}
