// L0005: replacing the live File during an iteration leaks the old handle.
flow main() => Int {
    hold first = "first.bin"
    hold second = "second.bin"
    change f = fileOpen(first, 2)
    change n = 0
    during n < 1 {
        f = fileOpen(second, 2)
        n += 1
    }
    fileClose(f)
    give 0
}
