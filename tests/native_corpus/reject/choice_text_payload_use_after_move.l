// Binding an owned Text payload consumes its whole choice value.
choice Message {
    Quiet,
    Named(Text),
}

flow discard(m: Message) {
}

flow inspect(m: Message) {
    choose m {
        Message.Quiet: {},
        Message.Named(name): { print(name) },
    }
    discard(m)
}

flow main() {
    inspect(Message.Named("owned"))
}
