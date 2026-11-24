// repeat with leave/proceed, and leave in an inner loop only exits that loop.
flow main() {
    change total = 0
    change i = 0
    repeat {
        i += 1
        when i > 5 { leave }
        when i == 3 { proceed }
        total += i
    }
    print(total)
    change pairs = 0
    each a among 0..6 {
        each b among 0..6 {
            when b > a { leave }
            when (a + b) % 2 == 1 { proceed }
            pairs += 1
        }
    }
    print(pairs)
}
