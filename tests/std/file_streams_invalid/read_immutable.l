// fileRead stores into its destination: an immutable list is rejected.
flow main() => Int {
    hold path = "imm.bin"
    hold f = fileOpen(path, 1)
    hold buf: List of[Int] = List[0]
    hold n = fileRead(f, buf, 1)
    fileClose(f)
    give n
}
