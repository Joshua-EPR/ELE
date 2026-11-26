// Montón (heap) del kernel: lista libre ordenada por dirección, primer
// ajuste, división de bloques grandes y fusión de vecinos al liberar.
//
// Vive en una región virtual propia que crece de 64 KiB en 64 KiB con
// marcos de mem.fisica. Cada bloque lleva una cabecera de 16 bytes:
// +0 tamaño total (cabecera incluida, múltiplo de 16) y, si está libre,
// +8 el siguiente bloque libre. La interfaz (reservar/liberar con tamaño
// conocido por la cabecera) es la que necesitará el asignador NEXO.

take nucleo.mem
take mem.fisica
take mem.paginacion

// 0xFFFF_C000_0000_0000: lejos del HHDM y de la imagen del kernel.
fixed BASE = 0xFFFFC00000000000
fixed CABECERA = 16
fixed CRECIMIENTO = 65536
fixed MINIMO = 32

// Estado: +0 fin de la región mapeada, +8 primer bloque libre (0 = ninguno),
// +16 bytes en uso.
flow estado() => Int { give reservar(24, 8) }

expose flow montonIniciar() {
    hold e = estado()
    escribir64(e, BASE)
    escribir64(e + 8, 0)
    escribir64(e + 16, 0)
}

expose flow montonEnUso() => Int { give leer64(estado() + 16) }

// Inserta el bloque `b` en la lista libre (por dirección) y lo fusiona con
// sus vecinos contiguos.
flow insertarLibre(b: Int) {
    hold e = estado()
    change previo = 0
    change actual = leer64(e + 8)
    during actual != 0 && actual < b {
        previo = actual
        actual = leer64(actual + 8)
    }
    escribir64(b + 8, actual)
    when previo == 0 { escribir64(e + 8, b) } otherwise { escribir64(previo + 8, b) }
    // Fusión con el siguiente.
    when actual != 0 && b + leer64(b) == actual {
        escribir64(b, leer64(b) + leer64(actual))
        escribir64(b + 8, leer64(actual + 8))
    }
    // Fusión con el anterior.
    when previo != 0 && previo + leer64(previo) == b {
        escribir64(previo, leer64(previo) + leer64(b))
        escribir64(previo + 8, leer64(b + 8))
    }
}

// Mapea al menos `bytes` más al final de la región y los añade libres.
flow crecer(bytes: Int) => Bool {
    hold e = estado()
    hold inicio = leer64(e)
    hold total = (bytes + CRECIMIENTO - 1) / CRECIMIENTO * CRECIMIENTO
    change d = 0
    during d < total {
        hold marco = memFisicaReservar()
        when marco == 0 { give false }
        when !pagMapear4k(inicio + d, marco, PAG_ESCRITURA) { give false }
        d += MARCO
    }
    escribir64(e, inicio + total)
    escribir64(inicio, total)
    insertarLibre(inicio)
    give true
}

// Dirección de `bytes` bytes alineados a 16, o 0 si no hay memoria.
expose flow montonReservar(bytes: Int) => Int {
    when bytes <= 0 { give 0 }
    hold e = estado()
    hold tam = (bytes + 15) / 16 * 16 + CABECERA
    change intentos = 0
    during intentos < 2 {
        change previo = 0
        change b = leer64(e + 8)
        during b != 0 {
            hold disponible = leer64(b)
            when disponible >= tam {
                change siguiente = leer64(b + 8)
                when disponible - tam >= MINIMO {
                    // Dividir: el resto queda libre en el mismo lugar de la lista.
                    hold resto = b + tam
                    escribir64(resto, disponible - tam)
                    escribir64(resto + 8, siguiente)
                    siguiente = resto
                    escribir64(b, tam)
                }
                when previo == 0 { escribir64(e + 8, siguiente) } otherwise { escribir64(previo + 8, siguiente) }
                escribir64(e + 16, leer64(e + 16) + leer64(b))
                give b + CABECERA
            }
            previo = b
            b = leer64(b + 8)
        }
        when !crecer(tam) { give 0 }
        intentos += 1
    }
    give 0
}

expose flow montonLiberar(dir: Int) {
    when dir == 0 { give }
    hold b = dir - CABECERA
    hold e = estado()
    escribir64(e + 16, leer64(e + 16) - leer64(b))
    insertarLibre(b)
}
