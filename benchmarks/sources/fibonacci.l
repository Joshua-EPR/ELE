// ELE Benchmark Source: fibonacci.l
// Recursive function calls, branches and returns
flow fibonacci(n: Int) => Int {
    when n <= 1 {
        give n
    }
    give fibonacci(n - 1) + fibonacci(n - 2)
}

flow main() {
    hold resultado = fibonacci(20)
    print("Fibonacci(20): {resultado}")
}
