// Comparisons and boolean logic, including short circuit with side effects.
fn marca(n: Int, r: Bool) -> Bool {
    print(n)
    return r
}
fn main() {
    print(1 < 2)
    print(2 <= 2)
    print(3 > 4)
    print(-1 >= -1)
    print(5 == 5)
    print(5 != 5)
    print(true == false)
    print(true != false)
    print(!true)
    print(marca(1, false) && marca(2, true))
    print(marca(3, true) || marca(4, true))
    print(marca(5, true) && marca(6, false))
    print(marca(7, false) || marca(8, true))
    print(1 < 2 && 3 < 4 || false)
}
