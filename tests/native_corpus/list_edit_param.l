// A list lent with edit is mutated by the callee and read through view.
flow fill(xs: edit List of[Int], n: Int) {
    each i among 0..n {
        xs@push(i * i)
    }
}

flow doubleAll(xs: edit List of[Int]) {
    each i among 0..xs.length {
        xs[i] = xs[i] * 2
    }
}

flow total(xs: view List of[Int]) => Int {
    change s = 0
    each x among xs {
        s += x
    }
    give s
}

flow main() {
    change xs: List of[Int] = List[]
    fill(edit xs, 5)
    print(total(view xs))
    doubleAll(edit xs)
    print(total(view xs))
    print(xs[4])
}
