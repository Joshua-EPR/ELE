space app.main
take std.io.print

shape Cuenta {
    expose titular: Text
    saldo: Float = 0.0
}

extend Cuenta {
    exclusive flow depositar(monto: Float) => Result of[(), Text] {
        when monto <= 0.0 {
            give Err("Monto inválido")
        }
        this.saldo += monto
        give Ok(())
    }

    flow consultar() => Float = this.saldo
}

flow main() {
    change cuenta = Cuenta(titular: "Ana")
    choose cuenta@depositar(50.0) {
        Ok(_): print(cuenta@consultar()),
        Err(error): print(error),
    }
}
