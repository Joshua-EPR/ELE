// Float literals are `fixed` constants (also negated); arithmetic on them is not.
fixed HALF: Float = 0.5
fixed NEG: Float = -2.5
fixed LIMIT: Float = 1e3

flow scale(x: Float) => Float = x * LIMIT

flow main() {
    print(HALF)
    print(NEG)
    print(scale(HALF))
    print(HALF + NEG)
}
