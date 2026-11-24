// Reading a name that was never declared.
flow main() => Int {
    give missing + 1
}
