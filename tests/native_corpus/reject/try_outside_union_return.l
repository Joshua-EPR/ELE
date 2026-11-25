flow source() => Result of[Int, Text] {
    give Err("failure")
}

flow wrong() => Int {
    hold value = source()?
    give value
}

flow main() {
    wrong()
}
