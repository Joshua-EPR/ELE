// Owned Option payloads move from Some; None evaluates the owned fallback.
flow fallback() => Text {
    print("fallback")
    give "default"
}

flow main() {
    hold present: Option of[Text] = Some("present")
    hold absent: Option of[Text] = None
    hold literal_present: Option of[Text] = Some("literal some")
    hold literal_absent: Option of[Text] = None
    print(present ?? fallback())
    print(absent ?? fallback())
    print(literal_present ?? "literal fallback")
    print(literal_absent ?? "literal fallback")
}
