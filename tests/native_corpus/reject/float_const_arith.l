// Constants are folded with integer arithmetic only: a Float literal is a
// constant, Float arithmetic in a const is not.
const HALF = 0.5
const SUM = HALF + 1.0

flow main() {
    print(SUM)
}
