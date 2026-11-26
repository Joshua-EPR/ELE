// ENCA interactiva: completa en pantalla el prefijo tecleado, byte a byte.
//
// El modelo está congelado: cada completado empieza con un documento nuevo
// (iniciarDocumento), pasa el prefijo por la corteza sin predecir ni
// aprender (condicionar) y genera con el byte de máxima probabilidad de la
// mezcla (voraz, como el autocompletado de la evaluación). Nada de lo
// aprendido cambia: el mismo prefijo da siempre el mismo completado.

take nucleo.cpu
take nucleo.mem
take lib.consola
take dispositivos.apic
take enca.modelo

fixed MAX_GENERADOS = 200

// Estado del decodificador UTF-8 de pantalla: +0 punto de código en
// construcción, +8 bytes de continuación que faltan.
flow decodificador() => Int { give reservar(16, 8) }

// Escribe el punto de código `cp` en UTF-8 en `dst`; devuelve cuántos bytes.
expose flow utf8Codificar(cp: Int, dst: Int) => Int {
    when cp < 0x80 {
        escribir8(dst, cp)
        give 1
    }
    when cp < 0x800 {
        escribir8(dst, 0xC0 | (cp >> 6))
        escribir8(dst + 1, 0x80 | (cp & 0x3F))
        give 2
    }
    when cp < 0x10000 {
        escribir8(dst, 0xE0 | (cp >> 12))
        escribir8(dst + 1, 0x80 | ((cp >> 6) & 0x3F))
        escribir8(dst + 2, 0x80 | (cp & 0x3F))
        give 3
    }
    escribir8(dst, 0xF0 | (cp >> 18))
    escribir8(dst + 1, 0x80 | ((cp >> 12) & 0x3F))
    escribir8(dst + 2, 0x80 | ((cp >> 6) & 0x3F))
    escribir8(dst + 3, 0x80 | (cp & 0x3F))
    give 4
}

// Muestra un byte generado: los de continuación se acumulan hasta tener el
// punto de código completo; un byte inválido se muestra como '?'.
flow mostrarByte(b: Int) {
    hold d = decodificador()
    when b < 0x80 {
        when leer64(d + 8) != 0 {
            kprintByte(63)
            escribir64(d + 8, 0)
        }
        when b < 32 { kprintByte(32) } otherwise { kprintByte(b) }
        give
    }
    when b >= 0xC0 {
        when leer64(d + 8) != 0 { kprintByte(63) }
        change falta = 1
        change cp = b & 0x1F
        when b >= 0xE0 {
            falta = 2
            cp = b & 0x0F
        }
        when b >= 0xF0 {
            falta = 3
            cp = b & 0x07
        }
        escribir64(d, cp)
        escribir64(d + 8, falta)
        give
    }
    when leer64(d + 8) == 0 {
        kprintByte(63)
        give
    }
    escribir64(d, (leer64(d) << 6) | (b & 0x3F))
    escribir64(d + 8, leer64(d + 8) - 1)
    when leer64(d + 8) == 0 { kprintCaracter(leer64(d)) }
}

// Completa el prefijo (n bytes UTF-8 en `prefijo`): imprime hasta 200 bytes
// o hasta el primer '\n' generado, y después los bytes y los ms por byte.
expose flow encaCompletar(m: Int, prefijo: Int, n: Int) {
    modeloIniciarDocumento(m)
    each i among 0..n { condicionar(m, leer8(prefijo + i)) }
    hold d = decodificador()
    escribir64(d, 0)
    escribir64(d + 8, 0)
    hold t0 = rdtsc()
    change generados = 0
    during generados < MAX_GENERADOS {
        hold b = modeloPredecirMezcla(m)
        when b == 10 { leave }
        mostrarByte(b)
        condicionar(m, b)
        generados += 1
    }
    hold t1 = rdtsc()
    when leer64(d + 8) != 0 { kprintByte(63) }
    kprintByte(10)
    hold cpm = tscCiclosPorMs()
    kprint(cadena("  ["))
    kprintEntero(generados)
    kprint(cadena(" bytes generados en "))
    kprintEntero((t1 - t0) / cpm)
    kprint(cadena(" ms"))
    when generados > 0 {
        // Milésimas de ms (µs) por byte.
        hold d1000 = (t1 - t0) * 1000 / cpm / generados
        kprint(cadena(", "))
        kprintEntero(d1000 / 1000)
        kprintByte(46)
        when d1000 % 1000 < 100 { kprintByte(48) }
        when d1000 % 1000 < 10 { kprintByte(48) }
        kprintEntero(d1000 % 1000)
        kprint(cadena(" ms por byte"))
    }
    kprintln(cadena("]"))
}
