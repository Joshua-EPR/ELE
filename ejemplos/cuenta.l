module app.main
import std.io.print

struct Cuenta {
    pub titular: Text
    saldo: Float = 0.0
}

impl Cuenta {
    mut fn depositar(monto: Float) -> Result<(), Text> {
        if monto <= 0.0 {
            return Err("Monto inválido")
        }
        self.saldo += monto
        return Ok(())
    }

    fn consultar() -> Float = self.saldo
}

fn main() {
    var cuenta = Cuenta(titular: "Ana")
    match cuenta.depositar(50.0) {
        Ok(_) => print(cuenta.consultar()),
        Err(error) => print(error),
    }
}
