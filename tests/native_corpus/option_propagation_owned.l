// The ? operator transfers an owned Text from Some and returns None early.
flow maybeMessage(n: Int) => Option of[Text] {
    when n == 0 { give None }
    give Some("message {n}")
}

flow forward(n: Int) => Option of[Text] {
    hold message = maybeMessage(n)?
    give Some(message)
}

flow show(n: Int) {
    choose forward(n) {
        Some(text): { print(text) },
        None: { print("none") },
    }
}

flow main() {
    show(1)
    show(0)
}
