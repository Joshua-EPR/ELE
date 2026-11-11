flow main() {
    change total = 0
    change i = 1
    during i <= 5 {
        total += i
        i += 1
    }
    print(total)
}
