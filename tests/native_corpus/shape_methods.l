// extend with methods: view receiver, exclusive receiver and a direct
// constructor, called with @.
shape Counter {
    value: Int
    stepBy: Int
}

extend Counter {
    direct flow make(stepBy: Int) => Counter {
        give Counter(value: 0, stepBy: stepBy)
    }

    flow current() => Int {
        give this.value
    }

    exclusive flow tick() => Int {
        this.value += this.stepBy
        give this.value
    }
}

flow main() {
    change c = Counter@make(3)
    c@tick()
    c@tick()
    print(c@current())
    print(c@tick())
}
