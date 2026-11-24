// Precedence, associativity, unary minus and compound assignment.
flow main() {
    print(2 + 3 * 4)
    print((2 + 3) * 4)
    print(20 - 5 - 3)
    print(100 / 10 / 5)
    print(2 * 3 + 4 * 5 - 6 / 2)
    print(-7 + 3)
    print(-(2 - 9))
    change x = 10
    x += 5
    print(x)
    x -= 20
    print(x)
    x *= -3
    print(x)
    x /= 4
    print(x)
    x %= 3
    print(x)
    hold big = 9223372036854775807
    print(big)
    hold small = -9223372036854775807 - 1
    print(small)
}
