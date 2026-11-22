// L0005: an edit parameter must not silently discard its live File.
flow swap(f: edit File) {
    hold other = "second.bin"
    f = fileOpen(other, 2)
}

flow main() => Int {
    hold first = "first.bin"
    change f = fileOpen(first, 2)
    swap(edit f)
    fileClose(f)
    give 0
}
