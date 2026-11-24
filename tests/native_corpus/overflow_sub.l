// Checked subtraction below Int.MIN exits with status 125.
flow sub(a: Int, b: Int) => Int {
    give a - b
}

flow main() => Int {
    hold min = -9223372036854775807 - 1
    print(sub(min, -1))
    hold boom = sub(min, 1)
    print(boom)
    give 0
}
