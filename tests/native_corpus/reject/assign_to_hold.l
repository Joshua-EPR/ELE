// hold bindings are immutable.
flow main() => Int {
    hold x = 1
    x = 2
    give x
}
