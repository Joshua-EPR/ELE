// Text moved into a flow and given back, then moved into a new binding.
flow greet(name: Text) => Text {
    give "Hola, {name}!"
}

flow pass(t: Text) => Text {
    give t
}

flow main() {
    hold a = greet("mundo")
    hold b = pass(a)
    hold c = b
    print(c)
    print(c.byteLength)
    change d = greet("uno")
    print(d)
    d = greet("dos")
    print(d)
}
