// Smoke program for the Stage-0-free seed bootstrap: checks that a program
// built by Gen3 reports a non-zero exit code exactly, not only stdout.
flow main() => Int {
    print("smoke exit")
    give 7
}
