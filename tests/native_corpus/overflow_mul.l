// Checked multiplication: 2^32 * (2^31 - 1) and -2^32 * 2^31 fit,
// 2^32 * 2^32 does not (status 125).
flow mul(a: Int, b: Int) => Int {
    give a * b
}

flow main() => Int {
    hold a = 4294967296
    print(mul(a, 2147483647))
    print(mul(-a, 2147483648))
    hold boom = mul(a, a)
    print(boom)
    give 0
}
