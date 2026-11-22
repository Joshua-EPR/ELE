// L0005: after a move the old binding no longer owns the File.
flow main() => Int {
    hold path = "moved.bin"
    hold f = fileOpen(path, 1)
    hold g = f
    fileClose(g)
    give fileClose(f)
}
