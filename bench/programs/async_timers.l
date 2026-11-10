async fn trabajo(n: Int) -> Int {
    await sleepMs(4 + n % 3)
    return n
}

async fn lote(n: Int) -> Int {
    var tareas = taskGroup<Int>()
    tareas.reserve(n)
    for i in 0..n {
        tareas.spawn(trabajo(i))
    }
    return (await tareas.joinAll()).length
}

async fn main() {
    print(await lote(10))
    print(await lote(100))
    print(await lote(1000))
    print(await lote(10000))
}
