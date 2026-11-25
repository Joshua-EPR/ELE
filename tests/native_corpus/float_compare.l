// Float comparisons are ordered: every comparison with NaN is false except
// `!=`, which is true.
flow report(label: Text, a: Float, b: Float) {
    print("{label} lt={a < b} le={a <= b} gt={a > b} ge={a >= b} eq={a == b} ne={a != b}")
}

flow main() {
    hold nan = 0.0 / 0.0
    hold inf = 1.0 / 0.0
    report("1<2", 1.0, 2.0)
    report("2<1", 2.0, 1.0)
    report("eq", 2.5, 2.5)
    report("nan,1", nan, 1.0)
    report("1,nan", 1.0, nan)
    report("nan,nan", nan, nan)
    report("inf,1", inf, 1.0)
    report("-inf,1", -inf, 1.0)
    report("0,-0", 0.0, -0.0)
    print(nan == nan)
    print(nan != nan)
    when nan < 1.0 || nan >= 1.0 {
        print("wrong")
    } otherwise {
        print("unordered")
    }
}
