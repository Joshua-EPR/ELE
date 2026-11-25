// Owned Option payloads move from Some; None evaluates the owned fallback.
flow fallback() => Text {
    print("fallback")
    give "default"
}

flow main() {
    hold present: Option of[Text] = Some("present")
    hold absent: Option of[Text] = None
    print(present ?? fallback())
    print(absent ?? fallback())
}
