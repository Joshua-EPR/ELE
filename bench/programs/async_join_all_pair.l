async fn trabajo(n: Int) -> List<Text> {
    await yieldNow()
    if n % 2 == 1 {
        await yieldNow()
    }
    return List["resultado {n}"]
}

async fn pares(n: Int) -> Int {
    var total = 0
    for i in 0..n / 2 {
        let resultados = await joinAll(List[spawn trabajo(i * 2), spawn trabajo(i * 2 + 1)])
        total += resultados[0].length + resultados[1].length
    }
    return total
}

async fn main() {
    let cien = await pares(100)
    print(cien)
    let mil = await pares(1000)
    print(mil)
}
