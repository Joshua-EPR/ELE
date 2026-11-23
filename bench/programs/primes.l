// Trial division: nested loops and early exits (ELE v2).
flow primo(n: Int) => Bool {
    when n < 2 {
        give false
    }
    hold d = 2
    during d * d <= n {
        when n % d == 0 {
            give false
        }
        d += 1
    }
    give true
}

flow main() {
    change c = 0
    each n among 0..2000000 {
        when primo(n) {
            c += 1
        }
    }
    print(c)
}
