// L0005: an open File reaches the end of its scope without fileClose.
flow main() => Int {
    hold path = "leak.bin"
    hold f = fileOpen(path, 1)
    give fileStatus(f)
}
