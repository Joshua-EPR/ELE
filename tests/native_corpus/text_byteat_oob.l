// byteAt past the end is bounds-checked at run time: status 127.
flow at(t: view Text, i: Int) => Int {
    give t@byteAt(i)
}

flow main() => Int {
    hold t = "abc"
    print(at(view t, 2))
    print(at(view t, 3))
    give 0
}
