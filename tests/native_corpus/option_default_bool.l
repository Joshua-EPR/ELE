// ?? preserves a false Some value and uses the fallback for None.
flow main() {
    hold present: Option of[Bool] = Some(false)
    hold absent: Option of[Bool] = None
    print(present ?? true)
    print(absent ?? false)
}
