// Comparison Benchmark: arithmetic_loop.l
flow compute(limit: Int) => Int {
    change acc: Int = 0
    change i: Int = 0
    during i < limit {
        acc = acc + (i * 3 + 1)
        i = i + 1
    }
    give acc
}

flow main() => Int {
    hold sum = compute(10000000)
    print(sum)
    give 0
}
