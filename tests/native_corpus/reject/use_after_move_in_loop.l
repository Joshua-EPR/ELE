// Moving an owned value inside a loop body moves it on the first iteration.
flow consume(s: Text) {
}

flow main() => Int {
    hold s = "mensaje"
    each i among 0..3 {
        consume(s)
    }
    give 0
}
