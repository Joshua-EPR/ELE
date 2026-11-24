// Float literals are outside the lexical subset of the ELE-written driver:
// the lexer error is reported at its position, never as invalid UTF-8.
flow main() => Int {
    hold half = 0.5
    give 0
}
