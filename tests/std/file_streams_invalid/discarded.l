// L0005: an opened File that is never bound is never closed.
flow main() => Int {
    hold path = "discarded.bin"
    fileOpen(path, 1)
    give 0
}
