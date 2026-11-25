// Explicit conversions: Float(Int) rounds to nearest, Int(Float) truncates
// toward zero, saturates at the Int range and maps NaN to 0.
flow main() {
    print(Float(3))
    print(Float(-7))
    print(Float(0))
    print(Float(9007199254740993))
    print(Float(9223372036854775807))
    print(Int(2.9))
    print(Int(-2.9))
    print(Int(0.999))
    print(Int(-0.5))
    print(Int(1e30))
    print(Int(-1e30))
    print(Int(9223372036854775807.0))
    print(Int(-9223372036854775808.0))
    print(Int(0.0 / 0.0))
    print(Int(1.0 / 0.0))
    print(Int(-1.0 / 0.0))
    hold n = 41
    print(Float(n) + 1.5)
    print(Int(Float(n) * 2.5))
    print(Float(2.5))
    print(Int(7))
}
