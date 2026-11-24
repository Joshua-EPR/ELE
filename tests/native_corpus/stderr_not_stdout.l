// printError writes to stderr: only the print lines reach stdout.
flow main() => Int {
    print("uno")
    printError("esto va a stderr")
    print("dos")
    give 0
}
