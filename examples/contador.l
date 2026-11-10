struct Contador {
    valor: Int = 0
}

impl Contador {
    mut fn incrementar() {
        self.valor += 1
    }

    fn obtener() -> Int {
        return self.valor
    }
}

fn main() {
    var contador = Contador()

    contador.incrementar()
    contador.incrementar()

    print("Valor: {contador.obtener()}")
}
