// extend on a choice: view methods with `choose this` over a choice that owns
// a Text payload, an exclusive method (calling another method on `this`) and
// direct constructor-like methods.
choice Estado {
    Pendiente,
    Completado,
    Error(Text),
}

extend Estado {
    direct flow fallo(motivo: Text) => Estado {
        give Estado@Error(motivo)
    }

    direct flow texto(e: Estado) => Text {
        give choose e {
            Estado.Pendiente: "pendiente",
            Estado.Completado: "completado",
            Estado.Error(mensaje): "error: {mensaje}",
        }
    }

    flow codigo() => Int {
        give choose this {
            Estado.Pendiente: 0,
            Estado.Completado: 1,
            Estado.Error(_): 2,
        }
    }

    flow esError() => Bool {
        choose this {
            Estado.Error(_): { give true },
            _: { give false },
        }
    }

    exclusive flow marcar() => Int {
        print("marcado")
        give this@codigo()
    }
}

flow main() {
    change e = Estado.Pendiente
    print(e@codigo())
    print(e@esError())
    print(e@marcar())
    change g = Estado@fallo("red")
    print(g@marcar())
    print(g@esError())
    hold f = Estado@fallo("directo")
    print(f@codigo())
    print(Estado@texto(f))
    print(Estado@fallo("x")@codigo())
    print(Estado@texto(Estado.Completado))
}
