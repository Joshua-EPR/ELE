// Integer arithmetic, precedence, unary minus, division/remainder signs.
fn main() {
    print(1 + 2 * 3 - 4)
    print((1 + 2) * (3 - 4))
    print(-7 / 2)
    print(-7 % 2)
    print(7 / -2)
    print(7 % -2)
    print(-(-5))
    print(9223372036854775807)
    print(-9223372036854775808)
    print(9223372036854775807 - 1 + 1)
    var x = 10
    x += 5
    x -= 3
    x *= 4
    x /= 6
    x %= 5
    print(x)
    print(100 / 7 * 7 + 100 % 7)
}
