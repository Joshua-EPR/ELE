// Bitwise and wrapping Int operators, hexadecimal and binary literals.
// A `0x`/`0b` literal is a 64-bit two's complement pattern, so a
// higher-half kernel address is a negative Int. Precedence follows Rust:
// * / % *%, + - +% -%, << >>, &, ^, |, then comparisons.
fixed MASK = 0xFF_00
fixed HIGHER_HALF = 0xFFFF_FFFF_8000_0000
fixed BITS = 0b1010
fixed PAGE = 1 << 12
fixed ALL_ONES = ~0
fixed WRAPPED = 0x7FFF_FFFF_FFFF_FFFF +% 1
fixed HIGH_WORD = HIGHER_HALF >> 32
fixed FOLDED = (0xF0 | 0x0F) ^ 0x3C & 0xFF

flow shiftLeft(a: Int, n: Int) => Int {
    give a << n
}

flow main() => Int {
    hold a = 0x1234
    hold b = 0x00ff
    print(a & b)
    print(a | b)
    print(a ^ b)
    print(~a)
    print(a << 4)
    print(a >> 4)
    print(-1 >> 60)
    print(-1 << 63)
    print(shiftLeft(3, 0))
    print(shiftLeft(1, 63))
    print(MASK)
    print(HIGHER_HALF)
    print(BITS)
    print(PAGE)
    print(ALL_ONES)
    print(WRAPPED)
    print(HIGH_WORD)
    print(FOLDED)
    hold max = 9223372036854775807
    hold min = -9223372036854775807 - 1
    print(max +% 1)
    print(min -% 1)
    print(max *% 3)
    print(a & 0xF == 4)
    print(1 + 2 << 3)
    print(6 & 3 | 8 ^ 1)
    print(1 << 2 < 5)
    // Page alignment, the reason these operators exist.
    hold address = 0x1_2345
    print(address & ~(PAGE - 1))
    give 0
}
