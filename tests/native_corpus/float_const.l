// Float literals are constants (also negated); arithmetic on them is not.
const HALF = 0.5
const NEG = -2.5
const LIMIT: Float = 1e3

flow scale(x: Float) => Float = x * LIMIT

flow main() {
    print(HALF)
    print(NEG)
    print(scale(HALF))
    print(HALF + NEG)
}
