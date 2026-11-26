// ENCA: ventana autoregresiva de bytes (VentanaBytes de parser_utf8.l).
// Anillo de los últimos `capacidad` bytes; 256 = "inicio de documento".
//
// Bloque (168 bytes, enteros de 8 bytes):
//   +0 capacidad   +8 cabeza   +16 llenos   +24 cabezaRespaldo
//   +32 llenosRespaldo   +40 bytes[8]   +104 respaldo[8]

take nucleo.cpu
take nucleo.mem
take enca.matematica

expose flow ventanaCrear(capacidad: Int) => Int {
    hold v = ncaReservar(168)
    escribir64(v, capacidad)
    escribir64(v + 8, 0)
    escribir64(v + 16, 0)
    escribir64(v + 24, 0)
    escribir64(v + 32, 0)
    each i among 0..capacidad {
        escribir64(v + 40 + i * 8, 256)
        escribir64(v + 104 + i * 8, 256)
    }
    give v
}

expose flow ventanaReiniciar(v: Int) {
    each i among 0..leer64(v) { escribir64(v + 40 + i * 8, 256) }
    escribir64(v + 8, 0)
    escribir64(v + 16, 0)
}

expose flow ventanaEmpujar(v: Int, byte: Int) {
    hold cap = leer64(v)
    hold cabeza = leer64(v + 8)
    escribir64(v + 40 + cabeza * 8, byte)
    escribir64(v + 8, (cabeza + 1) % cap)
    when leer64(v + 16) < cap { escribir64(v + 16, leer64(v + 16) + 1) }
}

// distancia 1 = último byte observado; fuera de la ventana => 256.
expose flow ventanaAtras(v: Int, distancia: Int) => Int {
    when distancia < 1 || distancia > leer64(v + 16) { give 256 }
    hold cap = leer64(v)
    hold indice = (leer64(v + 8) - distancia + cap) % cap
    give leer64(v + 40 + indice * 8)
}

// Hash de 31 bits de los últimos `orden` bytes.
expose flow ventanaHash(v: Int, orden: Int) => Int {
    hold modulus = 2147483647
    change hash = (orden * 7919 + 104729) % modulus
    each d among 1..=orden {
        hash = (hash * 1000003 + ventanaAtras(v, d) + 1) % modulus
    }
    give (hash * 48271) % modulus
}

expose flow ventanaGuardar(v: Int) {
    each i among 0..leer64(v) { escribir64(v + 104 + i * 8, leer64(v + 40 + i * 8)) }
    escribir64(v + 24, leer64(v + 8))
    escribir64(v + 32, leer64(v + 16))
}

expose flow ventanaRestaurar(v: Int) {
    each i among 0..leer64(v) { escribir64(v + 40 + i * 8, leer64(v + 104 + i * 8)) }
    escribir64(v + 8, leer64(v + 24))
    escribir64(v + 16, leer64(v + 32))
}
