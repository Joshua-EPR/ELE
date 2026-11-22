// L0005: the first fileClose consumes the File; a second one is use-after-move.
flow main() => Int {
    hold path = "double.bin"
    hold f = fileOpen(path, 1)
    fileClose(f)
    give fileClose(f)
}
