// L0005: closed on one branch only, so the File may still be open at exit.
flow main() => Int {
    hold path = "maybe.bin"
    hold f = fileOpen(path, 1)
    when processArgCount() > 0 { fileClose(f) }
    give 0
}
