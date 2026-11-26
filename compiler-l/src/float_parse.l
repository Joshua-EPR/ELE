// Correctly rounded conversion of a decimal Float literal to the IEEE-754
// binary64 bit pattern, in integer arithmetic only (round to nearest, ties
// to even, like Rust's `str::parse::<f64>` used by Stage 0). The compiler
// itself is built by the bootstrap seed, so it must not use Float.
//
// The value is D * 10^e with D a decimal integer. It is computed exactly as
// the ratio of two big integers (base 2^28 limbs, least significant first,
// no leading zero limbs; zero is the empty list), scaled so that the integer
// quotient has 56 or 57 bits, then rounded once to 53 bits (fewer for a
// subnormal) with the remainder kept as a sticky bit.

// Literals may carry any number of digits; beyond this many significant
// digits only "something non-zero follows" can still change the rounding
// (an exact binary64 midpoint has at most 767 significant digits).
flow fpDigitCap() => Int { give 800 }

flow fpBase() => Int { give 268435456 }

flow fpPow2(n: Int) => Int {
    change p = 1
    change i = 0
    during i < n {
        p = p * 2
        i += 1
    }
    give p
}

flow fpTrim(x: edit List of[Int]) {
    during x.length > 0 {
        hold last = x[x.length - 1]
        when last != 0 { leave }
        x@pop()
    }
}

// x = x * m + add, for 0 <= m <= 10^8 and 0 <= add < 2^28.
flow fpMulAdd(x: edit List of[Int], m: Int, add: Int) {
    change carry = add
    each i among 0..x.length {
        hold v = x[i] * m + carry
        x[i] = v % fpBase()
        carry = v / fpBase()
    }
    during carry > 0 {
        x@push(carry % fpBase())
        carry = carry / fpBase()
    }
}

flow fpMulPow10(x: edit List of[Int], count: Int) {
    change k = count
    during k >= 8 {
        fpMulAdd(edit x, 100000000, 0)
        k -= 8
    }
    when k > 0 {
        change m = 1
        each i among 0..k { m = m * 10 }
        fpMulAdd(edit x, m, 0)
    }
}

// x * 2^bits as a new list.
flow fpShiftLeft(x: view List of[Int], bits: Int) => List of[Int] {
    change out: List of[Int] = List[]
    when x.length == 0 { give out }
    hold whole = bits / 28
    hold part = fpPow2(bits % 28)
    each i among 0..whole { out@push(0) }
    change carry = 0
    each i among 0..x.length {
        hold v = x[i] * part + carry
        out@push(v % fpBase())
        carry = v / fpBase()
    }
    when carry > 0 { out@push(carry) }
    give out
}

flow fpCompare(a: view List of[Int], b: view List of[Int]) => Int {
    when a.length != b.length {
        when a.length < b.length { give -1 }
        give 1
    }
    change i = a.length
    during i > 0 {
        i -= 1
        when a[i] != b[i] {
            when a[i] < b[i] { give -1 }
            give 1
        }
    }
    give 0
}

// a = a - b, requires a >= b.
flow fpSub(a: edit List of[Int], b: view List of[Int]) {
    change borrow = 0
    each i among 0..a.length {
        change v = a[i] - borrow
        when i < b.length { v = v - b[i] }
        when v < 0 {
            v = v + fpBase()
            borrow = 1
        } otherwise {
            borrow = 0
        }
        a[i] = v
    }
    fpTrim(edit a)
}

flow fpBitLength(x: view List of[Int]) => Int {
    when x.length == 0 { give 0 }
    change top = x[x.length - 1]
    change bits = 0
    during top > 0 {
        top = top / 2
        bits += 1
    }
    give (x.length - 1) * 28 + bits
}

flow fpIntBitLength(value: Int) => Int {
    change v = value
    change bits = 0
    during v > 0 {
        v = v / 2
        bits += 1
    }
    give bits
}

// IEEE-754 binary64 bit pattern (sign bit clear) of the unsigned decimal
// literal source[start..end): digits and `_`, an optional `.digits` part and
// an optional `e|E[+-]digits` exponent (the shape the lexer accepts).
// Returns -1 when the value overflows to infinity.
expose flow floatLiteralBits(source: view Text, start: Int, end: Int) => Int {
    change digits: List of[Int] = List[]
    change frac_digits = 0
    change int_dropped = 0
    change dropped_nonzero = false
    change seen_dot = false
    change exp10 = 0
    change pos = start
    during pos < end {
        hold b = source@byteAt(pos)
        when b == 101 || b == 69 { leave }
        pos += 1
        when b == 95 { proceed }
        when b == 46 {
            seen_dot = true
            proceed
        }
        hold d = b - 48
        when digits.length >= fpDigitCap() {
            when !seen_dot { int_dropped += 1 }
            when d != 0 { dropped_nonzero = true }
            proceed
        }
        when seen_dot { frac_digits += 1 }
        when digits.length == 0 && d == 0 { proceed }
        digits@push(d)
    }
    when pos < end {
        // Exponent.
        pos += 1
        change negative = false
        when pos < end && source@byteAt(pos) == 45 {
            negative = true
            pos += 1
        } otherwise when pos < end && source@byteAt(pos) == 43 {
            pos += 1
        }
        change ev = 0
        during pos < end {
            when ev < 100000 { ev = ev * 10 + (source@byteAt(pos) - 48) }
            pos += 1
        }
        when negative { exp10 = 0 - ev } otherwise { exp10 = ev }
    }
    when digits.length == 0 { give 0 }
    change e = exp10 - frac_digits + int_dropped
    when dropped_nonzero {
        digits@push(1)
        e -= 1
    }
    hold magnitude = digits.length + e
    when magnitude > 310 { give -1 }
    when magnitude < -330 { give 0 }

    change num: List of[Int] = List[]
    change at = 0
    during at < digits.length {
        change chunk = 0
        change scale = 1
        change taken = 0
        during taken < 8 && at < digits.length {
            chunk = chunk * 10 + digits[at]
            scale = scale * 10
            at += 1
            taken += 1
        }
        fpMulAdd(edit num, scale, chunk)
    }
    change den: List of[Int] = List[]
    den@push(1)
    when e >= 0 { fpMulPow10(edit num, e) } otherwise { fpMulPow10(edit den, 0 - e) }

    // q = floor(num * 2^s / den) has 56 or 57 bits.
    hold s = 56 - (fpBitLength(view num) - fpBitLength(view den))
    change rem: List of[Int] = List[]
    change divisor: List of[Int] = List[]
    when s >= 0 {
        rem = fpShiftLeft(view num, s)
        divisor = fpShiftLeft(view den, 0)
    } otherwise {
        rem = fpShiftLeft(view num, 0)
        divisor = fpShiftLeft(view den, 0 - s)
    }
    change q = 0
    change weight = fpPow2(56)
    change bit = 56
    during bit >= 0 {
        hold shifted = fpShiftLeft(view divisor, bit)
        when fpCompare(view rem, view shifted) >= 0 {
            fpSub(edit rem, view shifted)
            q += weight
        }
        weight = weight / 2
        bit -= 1
    }
    hold sticky = rem.length > 0

    hold length = fpIntBitLength(q)
    change exponent = length - 1 - s
    change keep = 53
    when exponent < -1022 { keep = 1075 + exponent }
    when keep < 0 { give 0 }
    hold drop = length - keep
    hold unit = fpPow2(drop)
    change m = q / unit
    hold remainder = q - m * unit
    hold half = fpPow2(drop - 1)
    when remainder > half || (remainder == half && (sticky || m % 2 == 1)) { m += 1 }
    when exponent < -1022 { give m }
    when m == fpPow2(53) {
        m = fpPow2(52)
        exponent += 1
    }
    when exponent > 1023 { give -1 }
    give (exponent + 1023) * fpPow2(52) + (m - fpPow2(52))
}

// Sign flip of a bit pattern (unary minus on a literal): xor with 2^63.
expose flow floatBitsNegate(bits: Int) => Int {
    when bits < 0 { give bits + 9223372036854775807 + 1 }
    give bits - 9223372036854775807 - 1
}
