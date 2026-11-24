// A negative byteAt index is rejected by the same bounds check: status 127.
flow at(t: view Text, i: Int) => Int {
    give t@byteAt(i)
}

flow main() => Int {
    hold t = "abc"
    print(at(view t, 0))
    print(at(view t, -1))
    give 0
}
