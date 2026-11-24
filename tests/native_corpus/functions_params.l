// Parameters by value, multiple returns paths, expression-bodied flows,
// Bool and Text results, and calls nested as arguments.
flow square(x: Int) => Int = x * x

flow clamp(v: Int, lo: Int, hi: Int) => Int {
    when v < lo { give lo }
    when v > hi { give hi }
    give v
}

flow isEven(n: Int) => Bool = n % 2 == 0

flow describe(n: Int, even: Bool) => Text {
    when even { give "{n} es par" }
    give "{n} es impar"
}

flow sum4(a: Int, b: Int, c: Int, d: Int) => Int {
    give a * 1000 + b * 100 + c * 10 + d
}

flow noop() {
}

flow main() {
    print(square(12))
    print(clamp(-5, 0, 10))
    print(clamp(50, 0, 10))
    print(clamp(7, 0, 10))
    print(describe(4, isEven(4)))
    print(describe(7, isEven(7)))
    print(sum4(1, 2, 3, 4))
    print(sum4(square(2), clamp(9, 0, 3), 0, square(3)))
    noop()
    print("fin")
}
