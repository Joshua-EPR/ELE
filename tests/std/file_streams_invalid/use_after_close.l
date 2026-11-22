// L0005: a closed File can no longer be borrowed.
flow main() => Int {
    hold path = "after.bin"
    hold f = fileOpen(path, 1)
    fileClose(f)
    give fileSize(f)
}
