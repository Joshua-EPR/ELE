// Owned Option payloads need branch-sensitive moves and drops on both arms.
flow main() {
    hold present: Option of[Text] = Some("present")
    print(present ?? "fallback")
}
