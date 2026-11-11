// Construcción, paso y retorno por valor de un shape con 17 campos.
shape Grande {
    f00: Int
    f01: Int
    f02: Int
    f03: Int
    f04: Int
    f05: Int
    f06: Int
    f07: Int
    f08: Int
    f09: Int
    f10: Int
    f11: Int
    f12: Int
    f13: Int
    f14: Int
    f15: Int
    f16: Int
}

flow fabricar(base: Int) => Grande {
    give Grande(
        f00: base + 0,
        f01: base + 1,
        f02: base + 2,
        f03: base + 3,
        f04: base + 4,
        f05: base + 5,
        f06: base + 6,
        f07: base + 7,
        f08: base + 8,
        f09: base + 9,
        f10: base + 10,
        f11: base + 11,
        f12: base + 12,
        f13: base + 13,
        f14: base + 14,
        f15: base + 15,
        f16: base + 16
    )
}

flow suma(g: Grande) => Int {
    give g.f00 + g.f08 + g.f16
}

flow main() {
    hold g = fabricar(10)
    print(suma(g))
}
