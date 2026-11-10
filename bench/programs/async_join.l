async fn texto(n: Int) -> Text {
    await yieldNow()
    await yieldNow()
    return "texto {n}"
}
async fn lista(n: Int) -> List<Text> {
    await yieldNow()
    return List["primero {n}", "segundo {n}"]
}
async fn lote(n: Int) -> Int {
    var total = 0
    for i in 0..n / 2 {
        let par = await join(spawn texto(i), spawn lista(i))
        total += par.second.length
    }
    return total
}
async fn main() {
    let diez = await lote(10)
    print(diez)
    let cien = await lote(100)
    print(cien)
    let mil = await lote(1000)
    print(mil)
}
