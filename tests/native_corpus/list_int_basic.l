// List of[Int]: literal, push, index, length, element assignment and
// iteration with each ... among.
flow main() {
    change xs: List of[Int] = List[3, 1, 4]
    xs@push(1)
    xs@push(5)
    print(xs.length)
    print(xs[0])
    print(xs[4])
    xs[1] = 10
    change sum = 0
    each x among xs {
        sum += x
    }
    print(sum)
    change line = ""
    each i among 0..xs.length {
        line = "{line}{xs[i]} "
    }
    print(line)
    change grow: List of[Int] = List[]
    print(grow.length)
    each i among 0..1000 {
        grow@push(i * 3)
    }
    print(grow.length)
    print(grow[999])
}
