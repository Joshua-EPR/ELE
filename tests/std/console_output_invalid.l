// Negative semantic fixture: only List<Int> is accepted.
flow main() => Int {
    change wrong: List of[Text] = List["x"]
    give writeConsoleBytes(wrong)
}
