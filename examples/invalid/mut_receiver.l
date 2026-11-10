struct Contador {
    valor: Int = 0
}

impl Contador {
    mut fn incrementar() {
        self.valor += 1
    }
}

fn main() {
    let contador = Contador()
    contador.incrementar()
}
