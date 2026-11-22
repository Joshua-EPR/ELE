// L0016: a List would drop its Window without closing it.
flow main() => Int {
    hold title = "list"
    hold w = windowOpen(title, 200, 100)
    hold all = List[w]
    give all.length
}
