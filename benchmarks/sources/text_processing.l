// ELE Benchmark Source: text_processing.l
// Text dynamic allocation, interpolation, and ownership moves
flow greet(name: Text) => Text {
    give "Hello, {name}!"
}

flow main() {
    hold msg = greet("ELE Systems")
    print(msg)
}
