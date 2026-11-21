// L0005: a closed Window can no longer be borrowed.
flow main() => Int {
    hold title = "after"
    hold w = windowOpen(title, 200, 100)
    windowClose(w)
    give windowNext(w)
}
