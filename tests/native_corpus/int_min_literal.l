// -9223372036854775808 is the literal Int.MIN: the magnitude only exists
// directly under a unary minus.
fixed MINIMO = -9223372036854775808

flow minimo() => Int {
    give -9223372036854775808
}

flow main() {
    print(-9223372036854775808)
    print(minimo() + 1)
    print(-9223372036854775808 + 9223372036854775807)
    print(-9223372036854775807 - 1 == -9223372036854775808)
    print(MINIMO)
    hold x: Int = -9223372036854775808
    print(x < 0)
    each i among -9223372036854775808..-9223372036854775806 {
        print(i)
    }
    each j among -9223372036854775808..=-9223372036854775807 {
        print(j)
    }
    print(-9223372036854775807)
}
