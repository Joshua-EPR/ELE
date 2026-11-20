// ELE Benchmark Source: arithmetic.l
// Function calls and arithmetic computation
flow calc(x: Int, y: Int) => Int {
    give (x * 3 + y * 7) / 2
}

flow main() {
    hold valor = calc(100, 200)
    print(valor)
}
