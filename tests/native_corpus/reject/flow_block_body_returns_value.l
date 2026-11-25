// Without `=>` a block-bodied flow returns (): give-ing a value is an error.
flow cinco() {
    give 5
}

flow main() {
    print(cinco())
}
