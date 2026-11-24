// Direct and mutual recursion: fibonacci, factorial, gcd, ackermann.
flow fib(n: Int) => Int {
    when n < 2 { give n }
    give fib(n - 1) + fib(n - 2)
}

flow fact(n: Int) => Int {
    when n <= 1 { give 1 }
    give n * fact(n - 1)
}

flow gcd(a: Int, b: Int) => Int {
    when b == 0 { give a }
    give gcd(b, a % b)
}

flow isEven(n: Int) => Bool {
    when n == 0 { give true }
    give isOdd(n - 1)
}

flow isOdd(n: Int) => Bool {
    when n == 0 { give false }
    give isEven(n - 1)
}

flow ack(m: Int, n: Int) => Int {
    when m == 0 { give n + 1 }
    when n == 0 { give ack(m - 1, 1) }
    give ack(m - 1, ack(m, n - 1))
}

flow main() {
    print(fib(25))
    print(fact(20))
    print(gcd(1071, 462))
    print(isEven(100))
    print(isOdd(77))
    print(ack(2, 3))
}
