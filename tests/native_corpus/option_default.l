// The ?? operator gives the Some payload or the fallback for None.
flow find(xs: view List of[Int], wanted: Int) => Option of[Int] {
    each i among 0..xs.length {
        when xs[i] == wanted { give Some(i) }
    }
    give None
}

flow main() {
    hold xs: List of[Int] = List[5, 8, 13]
    print(find(view xs, 8) ?? -1)
    print(find(view xs, 9) ?? -1)
}
