// The ? operator propagates None from Option and unwraps Some.
flow maybeHalf(n: Int) => Option of[Int] {
    when n % 2 != 0 { give None }
    give Some(n / 2)
}

flow maybeQuarter(n: Int) => Option of[Int] {
    hold h = maybeHalf(n)?
    hold q = maybeHalf(h)?
    give Some(q)
}

flow show(n: Int) {
    choose maybeQuarter(n) {
        Some(v): { print("some {v}") },
        None: { print("none") },
    }
}

flow main() {
    show(20)
    show(7)
}
