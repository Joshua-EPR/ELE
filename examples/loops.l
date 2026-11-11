flow main() {
    change total = 0
    change i = 0
    repeat {
        i += 1
        when i > 5 { leave }
        when i == 3 { proceed }
        total += i
    }
    print(total)
}
