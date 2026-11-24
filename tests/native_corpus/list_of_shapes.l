// A list of shapes that own Text: push, field update through an index,
// iteration by view and a reduction.
shape Item {
    key: Text
    weight: Int
}

flow item(n: Int) => Item {
    give Item(key: "k{n}", weight: n)
}

flow total(items: view List of[Item]) => Int {
    change sum = 0
    each it among items {
        sum += it.weight
    }
    give sum
}

flow main() {
    change items: List of[Item] = List[]
    each i among 0..100 {
        items@push(item(i))
    }
    print(items.length)
    print(total(view items))
    items[5].weight = 1000
    print(total(view items))
    print(items[99].key)
    print(items[42].key.byteLength)
}
