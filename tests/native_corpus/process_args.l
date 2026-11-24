// processArgCount counts the arguments after the program name and
// processArg(i) gives Err(1) out of range; the runner passes no arguments.
flow main() => Int {
    hold n = processArgCount()
    print(n)
    choose processArg(0) {
        Ok(arg): { print("inesperado {arg}") },
        Err(code): { print("sin argumentos {code}") },
    }
    choose processArg(0 - 1) {
        Ok(arg): { print("inesperado {arg}") },
        Err(code): { print("negativo {code}") },
    }
    give n + 10
}
