// L0005: a File live on one incoming path cannot be replaced.
flow main() => Int {
    hold first = "first.bin"
    hold second = "second.bin"
    change f = fileOpen(first, 2)
    when processArgCount() > 0 {
        fileClose(f)
    }
    f = fileOpen(second, 2)
    fileClose(f)
    give 0
}
