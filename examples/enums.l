choice Estado {
    Pendiente,
    Completado,
    Error(Text),
}

extend Estado {
    flow codigo() => Int {
        give choose this {
            Estado.Pendiente: 0,
            Estado.Completado: 1,
            Estado.Error(_): 2,
        }
    }
}

flow mostrar(estado: Estado) {
    choose estado {
        Estado.Pendiente: print("Pendiente"),
        Estado.Completado: print("Completado"),
        Estado.Error(mensaje): print(mensaje),
    }
}

flow dividir(a: Float, b: Float) => Result of[Float, Text] {
    when b == 0.0 {
        give Err("División entre cero")
    }
    give Ok(a / b)
}

flow mitad_de_cociente(a: Float, b: Float) => Result of[Float, Text] {
    hold q = dividir(a, b)?
    give Ok(q / 2.0)
}

flow buscar(n: Int) => Int? {
    when n > 0 {
        give Some(n * 10)
    }
    give None
}

flow main() {
    mostrar(Estado.Pendiente)
    mostrar(Estado.Completado)
    mostrar(Estado@Error("Fallo de red"))
    print(Estado@Error("x")@codigo())

    choose mitad_de_cociente(10.0, 2.0) {
        Ok(v): print("ok {v}"),
        Err(e): print("error: {e}"),
    }
    choose mitad_de_cociente(1.0, 0.0) {
        Ok(v): print("ok {v}"),
        Err(e): print("error: {e}"),
    }

    hold nombre: Text? = None
    hold mostrar_nombre = nombre ?? "Invitado"
    print(mostrar_nombre)
    print(buscar(4) ?? -1)
    print(buscar(0) ?? -1)

    hold descripcion = choose buscar(3) {
        Some(30): "treinta",
        Some(_): "otro",
        None: "nada",
    }
    print(descripcion)
}
