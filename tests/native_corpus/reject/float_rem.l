// `%` on Float has no native lowering (Stage 0 native rejects it too).
flow main() {
    hold r = 5.5 % 2.0
    print(r)
}
