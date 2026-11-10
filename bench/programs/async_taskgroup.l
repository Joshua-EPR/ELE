async fn calcular(n: Int) -> Int {
    await yieldNow()
    if n % 2 == 1 {
        await yieldNow()
    }
    return n * 2
}

async fn lote(n: Int) -> Int {
    var grupo = taskGroup<Int>()
    grupo.reserve(n)
    for i in 0..n {
        grupo.spawn(calcular(i))
    }
    let resultados = await grupo.joinAll()
    var suma = 0
    for r in resultados {
        suma = suma + r
    }
    return suma
}

async fn main() {
    let diez = await lote(10)
    print(diez)
    let cien = await lote(100)
    print(cien)
    let mil = await lote(1000)
    print(mil)
    let diezmil = await lote(10000)
    print(diezmil)
}
