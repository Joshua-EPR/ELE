// during with leave and proceed: collatz length of 27 and the sum of
// odd numbers below 20 that are not multiples of 3.
flow collatz(start: Int) => Int {
    change n = start
    change steps = 0
    during n != 1 {
        when n % 2 == 0 {
            n = n / 2
        } otherwise {
            n = 3 * n + 1
        }
        steps += 1
    }
    give steps
}

flow main() {
    print(collatz(27))
    change i = 0
    change total = 0
    during true {
        i += 1
        when i >= 20 { leave }
        when i % 2 == 0 { proceed }
        when i % 3 == 0 { proceed }
        total += i
    }
    print(total)
    print(i)
}
