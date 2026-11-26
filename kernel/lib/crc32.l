// CRC-32 (IEEE 802.3, polinomio reflejado 0xEDB88320), con tabla de 256
// entradas calculada la primera vez.

take nucleo.mem

flow tabla() => Int { give reservar(2056, 8) }

flow preparar() {
    hold t = tabla()
    when leer64(t + 2048) == 1 { give }
    each n among 0..256 {
        change c = n
        each k among 0..8 {
            when c & 1 == 1 { c = 0xEDB88320 ^ (c >> 1) } otherwise { c = c >> 1 }
        }
        escribir64(t + n * 8, c)
    }
    escribir64(t + 2048, 1)
}

// CRC de `bytes` bytes en `dir`, continuando desde `previo` (0 al empezar).
expose flow crc32Continuar(previo: Int, dir: Int, bytes: Int) => Int {
    preparar()
    hold t = tabla()
    change c = previo ^ 0xFFFFFFFF
    change p = dir
    hold fin = dir + bytes
    during p != fin {
        c = leer64(t + ((c ^ leer8(p)) & 0xFF) * 8) ^ (c >> 8)
        p = p +% 1
    }
    give c ^ 0xFFFFFFFF
}

expose flow crc32(dir: Int, bytes: Int) => Int {
    give crc32Continuar(0, dir, bytes)
}
