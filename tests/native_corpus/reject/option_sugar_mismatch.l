flow nombre() => Text? {
    give 5
}

flow main() {
    hold n = nombre()
    print(n ?? "x")
}
