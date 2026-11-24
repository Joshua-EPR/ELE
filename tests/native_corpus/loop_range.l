// each i among a..b runs b - a times with an exclusive upper bound,
// zero times when the range is empty, and bounds can be expressions.
flow main() {
    change sum = 0
    each i among 0..5 {
        sum += i
    }
    print(sum)
    change empty = 0
    each i among 5..5 {
        empty += 1
    }
    each i among 7..3 {
        empty += 1
    }
    print(empty)
    hold lo = -3
    hold hi = 3
    change line = ""
    each i among lo..hi {
        line = "{line}{i},"
    }
    print(line)
    change squares = 0
    each i among 1..(hi * 2) {
        squares += i * i
    }
    print(squares)
}
