// The ? operator propagates Err out of the enclosing flow and unwraps Ok.
flow half(n: Int) => Result of[Int, Text] {
    when n % 2 != 0 { give Err("impar {n}") }
    give Ok(n / 2)
}

flow quarter(n: Int) => Result of[Int, Text] {
    hold h = half(n)?
    hold q = half(h)?
    give Ok(q)
}

flow show(n: Int) {
    choose quarter(n) {
        Ok(v): { print("ok {v}") },
        Err(e): { print("error {e}") },
    }
}

flow main() {
    show(20)
    show(6)
    show(7)
}
