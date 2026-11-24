// Checked addition: overflowing Int + Int stops the program with status 125
// after the output already written.
flow add(a: Int, b: Int) => Int {
    give a + b
}

flow main() => Int {
    hold max = 9223372036854775807
    print(add(max, 0))
    print("antes")
    hold boom = add(max, 1)
    print("no debe imprimirse")
    print(boom)
    give 0
}
