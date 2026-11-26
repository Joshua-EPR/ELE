// T? is sugar for Option of[T] in parameters, results and locals.
flow buscar(n: Int) => Int? {
    when n > 0 { give Some(n * 10) }
    give None
}

flow etiqueta(n: Int) => Text? {
    when n == 0 { give None }
    give Some("n{n}")
}

flow doble(valor: Int?) => Int {
    give (valor ?? 0) * 2
}

flow siguiente(n: Int) => Int? {
    hold v = buscar(n)?
    give Some(v + 1)
}

flow largo(n: Int) => Text? {
    hold t = etiqueta(n)?
    give Some(t)
}

flow main() {
    hold a: Int? = Some(1)
    hold b: Int? = None
    hold nombre: Text? = None
    print(a ?? -1)
    print(b ?? -1)
    print(nombre ?? "Invitado")
    print(doble(buscar(2)))
    print(doble(b))
    print(siguiente(3) ?? -1)
    print(siguiente(0) ?? -1)
    hold l7: Text? = largo(7)
    hold l0: Text? = largo(0)
    print(l7 ?? "ninguno")
    print(l0 ?? "ninguno")
}
