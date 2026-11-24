// Division by a zero known only at run time exits with status 125.
flow div(a: Int, b: Int) => Int {
    give a / b
}

flow main() => Int {
    print(div(10, 3))
    hold zero = 3 - 3
    print(div(10, zero))
    give 0
}
