// Calling a method that does not exist on List.
flow main() => Int {
    change xs: List of[Int] = List[]
    xs@shuffle()
    give 0
}
