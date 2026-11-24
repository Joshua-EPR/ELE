// An Int literal outside the 64-bit signed range.
flow main() => Int {
    hold x = 9223372036854775808
    give 0
}
