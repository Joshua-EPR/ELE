// CRC-32 (IEEE 802.3, polinomio reflejado 0xEDB88320), con tabla de 256
// entradas calculada la primera vez.

take nucleo.cpu
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

// ---- CRC-32C (Castagnoli, polinomio reflejado 0x82F63B78) -----------------
// Misma convención que crc32(): inversión inicial y final 0xFFFFFFFF.
// "123456789" => 0xE3069283.

flow tablaC() => Int { give reservar(2056, 8) }

flow prepararC() {
    hold t = tablaC()
    when leer64(t + 2048) == 1 { give }
    each n among 0..256 {
        change c = n
        each k among 0..8 {
            when c & 1 == 1 { c = 0x82F63B78 ^ (c >> 1) } otherwise { c = c >> 1 }
        }
        escribir64(t + n * 8, c)
    }
    escribir64(t + 2048, 1)
}

// Referencia por tabla, byte a byte.
expose flow crc32cSoft(dir: Int, bytes: Int) => Int {
    prepararC()
    hold t = tablaC()
    change c = 0xFFFFFFFF
    change p = dir
    hold fin = dir + bytes
    during p != fin {
        c = leer64(t + ((c ^ leer8(p)) & 0xFF) * 8) ^ (c >> 8)
        p = p +% 1
    }
    give c ^ 0xFFFFFFFF
}

// Con la instrucción CRC32 de SSE4.2: palabras de 8 bytes y cola por bytes.
expose flow crc32cSse(dir: Int, bytes: Int) => Int {
    change c = 0xFFFFFFFF
    change p = dir
    hold fin32 = dir + bytes - bytes % 32
    hold fin8 = dir + bytes - bytes % 8
    hold fin = dir + bytes
    // Bloques de 32 bytes: 4 palabras por vuelta reparten el costo del bucle.
    during p != fin32 {
        c = crc32c64(c, leer64(p))
        c = crc32c64(c, leer64(p +% 8))
        c = crc32c64(c, leer64(p +% 16))
        c = crc32c64(c, leer64(p +% 24))
        p = p +% 32
    }
    during p != fin8 {
        c = crc32c64(c, leer64(p))
        p = p +% 8
    }
    during p != fin {
        c = crc32c8(c, leer8(p))
        p = p +% 1
    }
    give c ^ 0xFFFFFFFF
}

// CRC-32C de `bytes` bytes continuando desde `previo` (0 al empezar): para
// verificar archivos grandes por tramos. crc32cContinuarSse(0, d, n) == crc32cSse(d, n)
// y encadenar tramos da el mismo CRC que el bloque entero.
expose flow crc32cContinuarSse(previo: Int, dir: Int, bytes: Int) => Int {
    change c = (previo ^ 0xFFFFFFFF) & 0xFFFFFFFF
    change p = dir
    hold fin32 = dir + bytes - bytes % 32
    hold fin8 = dir + bytes - bytes % 8
    hold fin = dir + bytes
    during p != fin32 {
        c = crc32c64(c, leer64(p))
        c = crc32c64(c, leer64(p +% 8))
        c = crc32c64(c, leer64(p +% 16))
        c = crc32c64(c, leer64(p +% 24))
        p = p +% 32
    }
    during p != fin8 {
        c = crc32c64(c, leer64(p))
        p = p +% 8
    }
    during p != fin {
        c = crc32c8(c, leer8(p))
        p = p +% 1
    }
    give c ^ 0xFFFFFFFF
}
