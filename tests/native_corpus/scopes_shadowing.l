// Block scopes: bindings declared inside a branch or loop body do not
// leak, and loop variables are fresh each iteration.
flow main() {
    hold x = 1
    change total = 0
    when x == 1 {
        hold y = 10
        total += y
    }
    each i among 0..3 {
        hold y = i * 100
        total += y
    }
    hold y = 5
    print(total + y + x)
}
