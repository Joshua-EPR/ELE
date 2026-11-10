fn main() {
    var total = 0
    var i = 0
    loop {
        i += 1
        if i > 5 { break }
        if i == 3 { continue }
        total += i
    }
    print(total)
}
