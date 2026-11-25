// Float in Text interpolation and in a larger formatted line.
flow label(price: Float) => Text {
    give "price={price}"
}

flow main() {
    hold a = 19.99
    hold b = -0.5
    hold nan = 0.0 / 0.0
    print("a={a} b={b}")
    print(label(1234.5))
    print("{a + b} {a * 2.0} {nan} {1.0 / 0.0} {-1.0 / 0.0}")
    change line = "x"
    line = "{line}:{3.25}"
    print(line)
    hold n = 7
    print("n={n} f={Float(n) / 2.0} t={n > 3}")
}
