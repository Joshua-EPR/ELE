// pop gives Option of[T]: Some(last) while elements remain, then None.
flow drain(xs: edit List of[Int]) => Int {
    change total = 0
    repeat {
        choose xs@pop() {
            Some(v): {
                print("pop {v}")
                total += v
            },
            None: { leave },
        }
    }
    give total
}

flow main() {
    change xs: List of[Int] = List[1, 2, 3]
    xs@push(4)
    print(drain(edit xs))
    print(xs.length)
    xs@push(9)
    print(xs.length)
    print(xs[0])
}
