// v2 borrow spellings: explicit shared and exclusive access.
flow inspect(value: view Int) => Int {
    give 42
}
flow consume_exclusive(value: edit Int) => Int {
    give 1
}
flow main() => Int {
    change number = 1
    hold base = inspect(view number)
    give base + consume_exclusive(edit number)
}
