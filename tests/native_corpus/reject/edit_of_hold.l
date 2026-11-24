// An edit loan needs a change binding.
flow bump(n: edit Int) {
    n = n + 1
}

flow main() => Int {
    hold n = 1
    bump(edit n)
    give n
}
