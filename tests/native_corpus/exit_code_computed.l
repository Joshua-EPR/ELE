// Exit status computed at run time; printed output precedes it.
flow suma(n: Int) => Int {
    change total = 0
    each i among 1..(n + 1) {
        total += i
    }
    give total
}

flow main() => Int {
    hold s = suma(20)
    print(s)
    give s % 256
}
