// when / otherwise when / otherwise, nested and as early returns.
flow classify(n: Int) => Text {
    when n < 0 {
        give "negativo"
    } otherwise when n == 0 {
        give "cero"
    } otherwise when n < 10 {
        give "digito"
    } otherwise {
        give "grande"
    }
}

flow sign(n: Int) => Int {
    when n > 0 { give 1 }
    when n < 0 { give -1 }
    give 0
}

flow main() {
    print(classify(-5))
    print(classify(0))
    print(classify(7))
    print(classify(42))
    change acc = 0
    each i among 0..10 {
        when i % 2 == 0 {
            when i % 4 == 0 {
                acc += 100
            } otherwise {
                acc += 10
            }
        } otherwise {
            acc += 1
        }
    }
    print(acc)
    print(sign(-9) + sign(0) * 10 + sign(3) * 100)
}
