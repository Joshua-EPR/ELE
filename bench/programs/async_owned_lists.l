struct Dato {
    nombre: Text
    ciudad: Text
}

async fn trabajar(entrada: List<Dato>, n: Int) -> Text {
    var datos = entrada
    await yieldNow()
    datos.push(Dato(nombre: "extra {n}", ciudad: "lugar {n}"))
    await yieldNow()
    match datos.pop() {
        Option.Some(d) => return d.nombre
        Option.None => return "vacío"
    }
}

async fn lote(n: Int) -> Int {
    for i in 0..n {
        let tarea = spawn trabajar(List[Dato(nombre: "nombre {i}", ciudad: "ciudad {i}")], i)
        let texto = await tarea
        let pendiente = spawn trabajar(List[Dato(nombre: "otro {i}", ciudad: "otra {i}")], i)
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
