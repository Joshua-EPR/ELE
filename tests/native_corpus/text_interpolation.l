// Interpolation of Int, Bool, Text and expressions; escaped braces.
flow main() {
    hold name = "ELE"
    hold n = 7
    hold ok = true
    print("hola {name}")
    print("{n} * {n} = {n * n}")
    print("ok={ok} no={!ok}")
    print("llaves: {{literal}} y {n}")
    print("negativo {-n} y cero {n - n}")
    print("")
    print("{name}{name}")
    hold nested = "<{name}:{n + 1}>"
    print("[{nested}]")
}
