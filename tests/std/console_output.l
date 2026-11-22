// Binary stdout, including NUL and UTF-8, with no implicit newline.
flow main() => Int {
    change empty: List of[Int] = List[]
    when writeConsoleBytes(empty) != 0 { give 3 }
    change bytes: List of[Int] = List[65, 0, 195, 169, 10]
    when writeConsoleBytes(bytes) != 0 { give 1 }
    change invalid: List of[Int] = List[256]
    when writeConsoleBytes(invalid) != -2 { give 2 }
    give 0
}
