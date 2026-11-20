// Comparison Benchmark: arithmetic_loop.rs
fn compute(limit: i64) -> i64 {
    let mut acc: i64 = 0;
    let mut i: i64 = 0;
    while i < limit {
        acc += i * 3 + 1;
        i += 1;
    }
    acc
}

fn main() {
    let sum = compute(10000000);
    println!("{}", sum);
}
