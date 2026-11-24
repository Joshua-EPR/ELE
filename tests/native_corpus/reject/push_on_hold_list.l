// push needs a mutable list; a hold binding is not.
flow main() => Int {
    hold xs: List of[Int] = List[]
    xs@push(1)
    give 0
}
