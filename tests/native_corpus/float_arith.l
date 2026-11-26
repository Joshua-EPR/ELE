// Float arithmetic, unary minus, params, returns and locals.
flow hyp2(a: Float, b: Float) => Float {
    give a * a + b * b
}

flow mean(a: Float, b: Float) => Float = (a + b) / 2.0

flow main() {
    hold x = 1.5 + 2.5
    print(x)
    print(10.0 - 0.25)
    print(3.0 * 0.5)
    print(7.0 / 2.0)
    print(-x)
    print(-(-x))
    print(hyp2(3.0, 4.0))
    print(mean(1.0, 2.0))
    change acc = 0.0
    each i among 0..10 {
        acc += 0.1
    }
    print(acc)
    acc = acc * 2.0
    print(acc)
    print(2.0 - 2.0)
    print(-(2.0 - 2.0))
    hold big = 1e308
    print(big * 10.0)
    print(-big * 10.0)
    hold zero = 0.0
    print(1.0 / zero)
    print(-1.0 / zero)
    print(zero / zero)
    print(zero * -1.0)
}
