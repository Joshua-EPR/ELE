// Trial division: nested loops and early exits.
fn primo(n: Int) -> Bool {
    if n < 2 { return false }
    var d = 2
    while d * d <= n {
        if n % d == 0 { return false }
        d += 1
    }
    return true
}
fn main() {
    var c = 0
    for n in 0..2000000 {
        if primo(n) { c += 1 }
    }
    print(c)
}
