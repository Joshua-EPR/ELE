shape Counter {
    value: Int
}
extend Counter {
    direct flow make(step: Int) => Counter {
        give Counter(value: step)
    }
}
flow main() {
    hold counter = Counter@make()
}
