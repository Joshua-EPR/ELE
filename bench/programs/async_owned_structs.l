struct Usuario {
    nombre: Text
    ciudad: Text
}

async fn trabajar(usuario: Usuario) -> Text {
    let nombre = usuario.nombre
    await yieldNow()
    await yieldNow()
    return nombre
}

async fn lote(n: Int) -> Int {
    for i in 0..n {
        let tarea = spawn trabajar(Usuario(nombre: "nombre {i}", ciudad: "ciudad {i}"))
        let texto = await tarea
        let pendiente = spawn trabajar(Usuario(nombre: "otro {i}", ciudad: "lugar {i}"))
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
