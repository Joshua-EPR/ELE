flow main() {
    hold maybe: Option of[Text] = Some("present")
    print(maybe ?? "fallback")
}
