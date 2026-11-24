// choose over Text, Int and Bool literal patterns: a borrowed Text
// parameter, an owned temporary (call result), a shape field, escapes,
// `\u{..}`, `{{`/`}}`, the empty Text and prefixes that must not match.
shape Item {
    name: Text
    count: Int
}

flow label(n: Int) => Text {
    choose n {
        0: { give "" }
        1: { give "uno" }
        -1: { give "menos" }
        1_000: { give "mil" }
        _: { give "otro" }
    }
}

flow score(word: view Text) => Int {
    choose word {
        "": { give 0 }
        "uno": { give 1 }
        "unos": { give 2 }
        "caf\u{E9}": { give 3 }
        "{{x}}": { give 4 }
        "a\"b": { give 5 }
        _: { give 9 }
    }
}

flow main() => Int {
    change total = 0
    each i among -1..3 {
        choose label(i) {
            "uno": { total = total + 10 }
            "menos": { total = total + 100 }
            "": { total = total + 1000 }
            _: { total = total + 1 }
        }
    }
    hold big = label(1000)
    hold item = Item(name: "café", count: 2)
    choose item.name {
        "café": { total = total + 20000 }
        _: {}
    }
    hold w0 = ""
    hold w1 = "uno"
    hold w2 = "unos"
    hold w3 = "café"
    hold w4 = "{{x}}"
    hold w5 = "a\"b"
    hold w6 = "un"
    print("{score(w0)} {score(w1)} {score(w2)} {score(w3)} {score(w4)} {score(w5)} {score(w6)}")
    hold flag = item.count > 1
    choose flag {
        false: { total = total + 7 }
        true: { total = total + 300000 }
    }
    print("{big} {item.name} {total}")
    give total % 100
}
