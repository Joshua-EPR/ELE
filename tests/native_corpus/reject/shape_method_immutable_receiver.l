shape Counter {
    value: Int
}
extend Counter {
    exclusive flow tick() => Int {
        this.value += 1
        give this.value
    }
}
flow main() {
    hold counter = Counter(value: 0)
    counter@tick()
}
