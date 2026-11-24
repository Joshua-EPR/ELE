// A negative list index is bounds-checked: status 127.
flow main() => Int {
    hold xs: List of[Int] = List[10, 20, 30]
    hold i = 1 - 2
    print(xs[0])
    print(xs[i])
    give 0
}
