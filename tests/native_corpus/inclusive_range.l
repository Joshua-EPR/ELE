// `a..=b` includes b; `a..b` does not.
flow main() {
    change total = 0
    each i among 1..=10 {
        total += i
    }
    print(total)
    each j among 0..3 {
        print(j)
    }
    each k among 5..=4 {
        print(k)
    }
    each m among 3..=3 {
        print(m)
    }
}
