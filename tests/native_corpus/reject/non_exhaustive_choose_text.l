// A choose over Text needs a `_` arm: literals never cover every value.
flow code(word: view Text) => Int {
    choose word {
        "uno": { give 1 }
        "dos": { give 2 }
    }
    give 0
}

flow main() => Int {
    hold w = "tres"
    give code(w)
}
