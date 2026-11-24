// The right side of ?? is evaluated only when the Option is None.
flow fallback() => Int {
    print("fallback")
    give 9
}

flow main() {
    print(Some(7) ?? fallback())
    hold absent: Option of[Int] = None
    print(absent ?? fallback())
}
