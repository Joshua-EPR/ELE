// Dynamic Text: one interpolation (allocation + drop) per iteration (ELE v2).
flow main() {
    change ultimo = ""
    each i among 0..1000000 {
        ultimo = "item {i}: {i * 2} {i % 7 == 0}"
    }
    print(ultimo)
}
