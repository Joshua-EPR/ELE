flow main() {
    hold maybe: Option of[Text] = Some("owned")
    print(maybe ?? "first fallback")
    print(maybe ?? "second fallback")
}
