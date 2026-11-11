fixed RESPUESTA: Int = BASE * 2
fixed BASE = 21
fixed ACTIVO: Bool = RESPUESTA == 42 && !false

flow main() {
    fixed siguiente = RESPUESTA + 1
    print(RESPUESTA)
    print(siguiente)
    print(ACTIVO)
}
