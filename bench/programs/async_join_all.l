async fn trabajo(n: Int) -> List<Text> {
    await yieldNow()
    if n % 2 == 1 {
        await yieldNow()
    }
    return List["resultado {n}"]
}

async fn lote(n: Int) -> Int {
    var tareas = taskGroup(trabajo)
    tareas.reserve(n)
    for i in 0..n {
        tareas.push(spawn trabajo(i))
    }
    let resultados = await joinAll(tareas)
    return resultados.length
}

async fn main() {
    let diez = await lote(10)
    print(diez)
    let cien = await lote(100)
    print(cien)
    let mil = await lote(1000)
    print(mil)
    let miles = await lote(10000)
    print(miles)
}
