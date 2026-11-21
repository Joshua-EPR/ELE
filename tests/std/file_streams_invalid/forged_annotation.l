// An Int literal cannot be given the File type.
flow main() => Int {
    hold f: File = 3
    give fileClose(f)
}
