// Recursion, mutual recursion, inferred returns and constants.
const LIMITE = 20
fn fibonacci(n: Int) -> Int {
    if n <= 1 {
        return n
    }
    return fibonacci(n - 1) + fibonacci(n - 2)
}
fn factorial(n: Int) -> Int {
    if n == 0 { return 1 }
    return n * factorial(n - 1)
}
fn par(n: Int) -> Bool {
    if n == 0 { return true }
    return impar(n - 1)
}
fn impar(n: Int) -> Bool {
    if n == 0 { return false }
    return par(n - 1)
}
fn ackermann(m: Int, n: Int) -> Int {
    if m == 0 { return n + 1 }
    if n == 0 { return ackermann(m - 1, 1) }
    return ackermann(m - 1, ackermann(m, n - 1))
}
fn doble(x: Int) = x * 2
fn main() {
    print(fibonacci(LIMITE))
    print(factorial(20))
    print(par(10))
    print(impar(7))
    print(ackermann(2, 3))
    print(doble(doble(21)))
}
