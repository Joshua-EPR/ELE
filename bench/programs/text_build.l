// Dynamic Text: one interpolation (allocation + drop) per iteration.
fn main() {
    var ultimo = ""
    for i in 0..1000000 {
        ultimo = "item {i}: {i * 2} {i % 7 == 0}"
    }
    print(ultimo)
}
