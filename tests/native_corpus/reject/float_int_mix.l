// No implicit Int/Float conversion: mixing them in arithmetic is L0003.
flow main() {
    hold n = 2
    hold total = n + 1.5
    print(total)
}
