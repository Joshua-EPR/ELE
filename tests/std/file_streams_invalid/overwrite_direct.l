// L0005: assigning a new File must not silently discard the live one.
flow main() => Int {
    hold first = "first.bin"
    hold second = "second.bin"
    change f = fileOpen(first, 2)
    f = fileOpen(second, 2)
    fileClose(f)
    give 0
}
