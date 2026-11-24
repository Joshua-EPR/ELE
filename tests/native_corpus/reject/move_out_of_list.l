// An owned element cannot be moved out of a collection by indexing.
flow main() => Int {
    hold xs: List of[Text] = List["a", "b"]
    hold first = xs[0]
    give 0
}
