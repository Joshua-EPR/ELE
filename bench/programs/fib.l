// Recursive calls and checked additions (ELE v2).
flow fib(n: Int) => Int {
    when n < 2 {
        give n
    }
    give fib(n - 1) + fib(n - 2)
}

flow main() {
    print(fib(32))
}
