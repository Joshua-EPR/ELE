// An inferred result cannot depend on itself: annotate it with `=>`.
flow cuenta(n: Int) = cuenta(n - 1)

flow main() {
    print(cuenta(3))
}
