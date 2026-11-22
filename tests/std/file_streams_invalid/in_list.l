// L0016: a List would drop its File without closing it.
flow main() => Int {
    hold path = "list.bin"
    hold f = fileOpen(path, 1)
    hold files = List[f]
    give files.length
}
