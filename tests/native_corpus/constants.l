// fixed constants at module level used in expressions and as bounds.
fixed LIMIT: Int = 5
fixed BASE: Int = 1000
fixed GREETING: Text = "constante"

flow main() => Int {
    change total = 0
    each i among 0..LIMIT {
        total += BASE + i
    }
    print(total)
    print(GREETING)
    give LIMIT
}
