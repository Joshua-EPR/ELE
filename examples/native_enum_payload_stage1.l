// Phase 8.7.4.3: Stage 1 must produce real typed ELE-LIR from this .l file.
enum Estado {
    No,
    Si(Int),
    Flag(Bool),
}

fn sumar(x: Int) -> Int {
    return x + 2
}

fn main() -> Int {
    let estado = Estado.Si(40)
    match estado {
        Estado.No => { return 1 },
        Estado.Si(v) => { return sumar(v) },
        Estado.Flag(flag) => { return 0 },
    }
    return 3
}
