// ELE Benchmark Source: main.l (Multi-module)
// Imports helper module via `take math_helper`
take math_helper

flow main() => Int {
    hold x = addNums(20, 22)
    hold y = mulNums(x, 2)
    print("Resultado: {y}")
    give 0
}
