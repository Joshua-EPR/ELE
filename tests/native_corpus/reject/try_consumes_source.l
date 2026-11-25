flow source() => Result of[Int, Text] {
    give Ok(10)
}

flow wrong() => Result of[Int, Text] {
    hold result = source()
    hold value = result?
    give result
}

flow main() {
    wrong()
}
