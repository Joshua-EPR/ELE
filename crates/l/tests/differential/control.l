// if/else-if, while, loop with break/continue, for ranges and nesting.
fn clasifica(n: Int) -> Text {
    if n < 0 {
        return "negativo"
    } else if n == 0 {
        return "cero"
    } else {
        return "positivo"
    }
}
fn main() {
    print(clasifica(-3))
    print(clasifica(0))
    print(clasifica(8))
    var i = 0
    var suma = 0
    while i < 100 {
        i += 1
        if i % 3 == 0 {
            continue
        }
        if i > 20 {
            break
        }
        suma += i
    }
    print(suma)
    var n = 0
    loop {
        n += 7
        if n > 50 { break }
    }
    print(n)
    for a in 1..=3 {
        for b in 0..a {
            print(a * 10 + b)
        }
    }
    for k in 5..1 { print(k) }
    for k in 9223372036854775805..=9223372036854775807 { print(k) }
    for k in -9223372036854775808..-9223372036854775806 { print(k) }
}
