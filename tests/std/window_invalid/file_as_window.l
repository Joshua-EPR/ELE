// L0004: a File is not a Window, even though both are one word below sema.
flow main() => Int {
    hold path = "x.bin"
    hold f = fileOpen(path, 1)
    hold r = windowPresent(f)
    fileClose(f)
    give r
}
