// L0005: replacement on only one branch still leaks on that branch.
flow main() => Int {
    hold first = "first.bin"
    hold second = "second.bin"
    change f = fileOpen(first, 2)
    when processArgCount() > 0 {
        f = fileOpen(second, 2)
    }
    fileClose(f)
    give 0
}
