flow fibonacci(n: Int) => Int {
    when n <= 1 {
        give n
    }

    give fibonacci(n - 1) + fibonacci(n - 2)
}

flow main() {
    hold resultado = fibonacci(10)
    print("Fibonacci: {resultado}")
}
