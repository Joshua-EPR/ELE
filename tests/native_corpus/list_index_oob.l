// Indexing past the end of a list is bounds-checked: status 127.
flow at(xs: view List of[Int], i: Int) => Int {
    give xs[i]
}

flow main() => Int {
    hold xs: List of[Int] = List[10, 20, 30]
    print(at(view xs, 2))
    print(at(view xs, 3))
    give 0
}
