// A shape moved into a new binding cannot be read through the old one.
shape Box {
    label: Text
}

flow main() => Int {
    hold a = Box(label: "x")
    hold b = a
    print(a.label)
    give 0
}
