use project_l::check;

#[test]
fn migrated_basic_benchmarks_use_canonical_v2_syntax() {
    for source in [
        include_str!("../../../bench/programs/fib.l"),
        include_str!("../../../bench/programs/primes.l"),
        include_str!("../../../bench/programs/collatz.l"),
        include_str!("../../../bench/programs/sum_loop.l"),
    ] {
        check(source).unwrap();
    }
}
