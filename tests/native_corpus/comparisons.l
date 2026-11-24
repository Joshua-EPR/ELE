// Relational and equality operators on Int and Bool.
flow show(label: Text, v: Bool) {
    print("{label}={v}")
}

flow main() {
    hold a = 3
    hold b = 5
    show("a<b", a < b)
    show("a<=b", a <= b)
    show("a>b", a > b)
    show("a>=b", a >= b)
    show("a==b", a == b)
    show("a!=b", a != b)
    show("b<=b", b <= b)
    show("b>=b", b >= b)
    show("neg", -1 < 0)
    show("minmax", -9223372036854775807 - 1 < 9223372036854775807)
    show("booleq", true == true)
    show("boolne", true != false)
    show("boolfalse", true == false)
}
