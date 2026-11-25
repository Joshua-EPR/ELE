// The ? operator transfers owned Text payloads out of Result on either path.
flow message(n: Int) => Result of[Text, Text] {
    when n == 0 { give Err("failure {n}") }
    give Ok("success {n}")
}

flow forward(n: Int) => Result of[Text, Text] {
    hold text = message(n)?
    give Ok(text)
}

flow show(n: Int) {
    choose forward(n) {
        Ok(text): { print(text) },
        Err(error): { print(error) },
    }
}

flow main() {
    show(1)
    show(0)
}
