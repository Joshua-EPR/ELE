// List of[Text]: owned and literal elements, iteration by view and
// lists given back from a flow.
flow names(n: Int) => List of[Text] {
    change out: List of[Text] = List["cero"]
    each i among 1..n {
        out@push("n{i}")
    }
    give out
}

flow main() {
    hold ns = names(5)
    print(ns.length)
    each name among ns {
        print(name)
    }
    print(ns[4].byteLength)
    change total = 0
    each i among 0..ns.length {
        total += ns[i].byteLength
    }
    print(total)
}
