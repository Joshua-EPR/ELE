// ELE's canonical, non-Rust surface syntax (bootstrap-compatible subset).
choice Estado {
    No,
    Si(Int),
    Flag(Bool),
}

flow sumar(x: Int) => Int {
    give x + 2
}

flow main() => Int {
    hold estado = Estado@Si(40)
    choose estado {
        Estado.No: { give 1 },
        Estado.Si(v): { give sumar(v) },
        Estado.Flag(flag): { give 0 },
    }
    give 3
}
