// Prelude of ELE, compiled before every program.
// Ordinary generic enums: the compiler only knows that their variants are
// usable unqualified (Some/None/Ok/Err) and that `??` and `?` are defined
// on Option and Result (spec §7).

expose choice Option of[T] {
    Some(T)
    None
}

expose choice Result of[T, E] {
    Ok(T)
    Err(E)
}
