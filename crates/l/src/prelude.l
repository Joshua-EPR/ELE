// Prelude of ELE, compiled before every program.
// Ordinary generic enums: the compiler only knows that their variants are
// usable unqualified (Some/None/Ok/Err) and that `??` and `?` are defined
// on Option and Result (spec §7).

pub enum Option<T> {
    Some(T)
    None
}

pub enum Result<T, E> {
    Ok(T)
    Err(E)
}
