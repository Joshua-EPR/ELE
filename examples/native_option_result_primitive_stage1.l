// Stage 1 primitive tagged-union lowering: Option / Result share the
// existing checked enum representation, but keep their own generic types.
// Expected process exit status: 50.
fn takeOption(value: Option<Int>) -> Int {
    match value {
        Some(item) => { return item }
        None => { return 0 }
    }
}

fn takeResult(value: Result<Int, Bool>) -> Int {
    match value {
        Ok(item) => { return item }
        Err(problem) => {
            if problem { return 8 }
            return 0
        }
    }
}

fn main() -> Int {
    let one: Option<Int> = Some(20)
    let empty: Option<Int> = None
    let good: Result<Int, Bool> = Ok(22)
    let bad: Result<Int, Bool> = Err(true)
    return takeOption(one) + takeOption(empty) + takeResult(good) + takeResult(bad)
}
