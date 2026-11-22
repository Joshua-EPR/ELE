// Comparison Benchmark: fibonacci_recursive.l
flow fib(n: Int) => Int {
    when n <= 1 {
        give n
    }
    give fib(n - 1) + fib(n - 2)
}

flow main() => Int {
    hold res = fib(25)
    print(res)
    give 0
}
