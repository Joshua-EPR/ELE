// Constants are folded with integer arithmetic only: a Float literal is a
// constant, Float arithmetic in a `fixed` is not.
fixed HALF: Float = 0.5
fixed SUM: Float = HALF + 1.0

flow main() {
    print(SUM)
}
