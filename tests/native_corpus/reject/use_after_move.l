// A Text moved into a flow cannot be used again.
flow consume(s: Text) {
}

flow main() => Int {
    hold s = "mensaje"
    consume(s)
    consume(s)
    give 0
}
