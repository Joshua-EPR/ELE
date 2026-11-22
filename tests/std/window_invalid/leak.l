// L0005: an open Window reaches the end of its scope without windowClose.
flow main() => Int {
    hold title = "leak"
    hold w = windowOpen(title, 200, 100)
    give windowStatus(w)
}
