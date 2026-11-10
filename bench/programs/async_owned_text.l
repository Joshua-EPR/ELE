async fn trabajo(n: Int) -> Text {
    let texto = "recurso {n}"
    await yieldNow()
    await yieldNow()
    return texto
}

async fn lote(n: Int) -> Int {
    for i in 0..n {
        let tarea = spawn trabajo(i)
        let texto = await tarea
        let pendiente = spawn trabajo(i)
        await yieldNow()
    }
    return n
}

async fn main() {
    let diez = await lote(10)
    print(diez)
    let cien = await lote(100)
    print(cien)
    let mil = await lote(1000)
    print(mil)
}
