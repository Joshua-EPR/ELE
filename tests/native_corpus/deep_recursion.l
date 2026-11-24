// 100000 nested calls fit in the native stack.
flow depth(n: Int) => Int {
    when n == 0 { give 0 }
    give 1 + depth(n - 1)
}

flow main() {
    print(depth(100000))
}
