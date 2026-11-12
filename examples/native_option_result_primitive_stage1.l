// Primitive Option/Result lowering through checked ELE-LIR enum operations.
// Expected Linux ELF64 process exit: 50.
flow takeOption(value: Option of[Int]) => Int {
    choose value {
        Some(item): { give item },
        None: { give 0 },
    }
}

flow takeResult(value: Result of[Int, Bool]) => Int {
    choose value {
        Ok(item): { give item },
        Err(problem): {
            when problem { give 8 }
            give 0
        },
    }
}

flow main() => Int {
    hold one: Option of[Int] = Some(20)
    hold empty: Option of[Int] = None
    hold good: Result of[Int, Bool] = Ok(22)
    hold bad: Result of[Int, Bool] = Err(true)
    give takeOption(one) + takeOption(empty) + takeResult(good) + takeResult(bad)
}
