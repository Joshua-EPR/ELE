enum Estado {
    Pendiente
    Completado
    Error(Text)
}

fn mostrar(estado: Estado) {
    match estado {
        Estado.Pendiente => print("Pendiente"),
        Estado.Error(mensaje) => print(mensaje),
    }
}

fn main() {
    mostrar(Estado.Completado)
}
