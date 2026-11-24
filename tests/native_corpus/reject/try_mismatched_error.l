flow source() => Result of[Int, Text] {
    give Err("failure")
}

flow wrong() => Result of[Int, Int] {
    hold value = source()?
    give Ok(value)
}

flow main() {
    wrong()
}
