const RESPUESTA: Int = BASE * 2
const BASE = 21
const ACTIVO: Bool = RESPUESTA == 42 && !false

fn main() {
    const siguiente = RESPUESTA + 1
    print(RESPUESTA)
    print(siguiente)
    print(ACTIVO)
}
