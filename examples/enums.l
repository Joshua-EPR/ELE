enum Estado {
    Pendiente
    Completado
    Error(Text)
}

impl Estado {
    fn codigo() -> Int {
        return match self {
            Estado.Pendiente => 0,
            Estado.Completado => 1,
            Estado.Error(_) => 2,
        }
    }
}

fn mostrar(estado: Estado) {
    match estado {
        Estado.Pendiente => print("Pendiente"),
        Estado.Completado => print("Completado"),
        Estado.Error(mensaje) => print(mensaje),
    }
}

fn dividir(a: Float, b: Float) -> Result<Float, Text> {
    if b == 0.0 {
        return Err("División entre cero")
    }
    return Ok(a / b)
}

fn mitad_de_cociente(a: Float, b: Float) -> Result<Float, Text> {
    let q = dividir(a, b)?
    return Ok(q / 2.0)
}

fn buscar(n: Int) -> Int? {
    if n > 0 {
        return Some(n * 10)
    }
    return None
}

fn main() {
    mostrar(Estado.Pendiente)
    mostrar(Estado.Completado)
    mostrar(Estado.Error("Fallo de red"))
    print(Estado.Error("x").codigo())

    match mitad_de_cociente(10.0, 2.0) {
        Ok(v) => print("ok {v}"),
        Err(e) => print("error: {e}"),
    }
    match mitad_de_cociente(1.0, 0.0) {
        Ok(v) => print("ok {v}"),
        Err(e) => print("error: {e}"),
    }

    let nombre: Text? = None
    let mostrar_nombre = nombre ?? "Invitado"
    print(mostrar_nombre)
    print(buscar(4) ?? -1)
    print(buscar(0) ?? -1)

    let descripcion = match buscar(3) {
        Some(30) => "treinta",
        Some(_) => "otro",
        None => "nada",
    }
    print(descripcion)
}
