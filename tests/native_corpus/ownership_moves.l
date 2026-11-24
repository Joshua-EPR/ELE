// Moves of owned values into flows, shapes and lists, and reinitialization
// of a change binding after its value was moved out.
shape Box {
    label: Text
    items: List of[Text]
}

flow consume(t: Text) => Int {
    give t.byteLength
}

flow pack(label: Text, first: Text) => Box {
    change items: List of[Text] = List[]
    items@push(first)
    give Box(label: label, items: items)
}

flow main() {
    change t = "abcdef"
    print(consume(t))
    t = "xy"
    print(consume(t))
    hold label = "etiqueta"
    hold first = "primero"
    change b = pack(label, first)
    b.items@push("segundo")
    print(b.label)
    print(b.items.length)
    each item among b.items {
        print(item)
    }
    hold moved = b
    print(moved.items[1])
}
