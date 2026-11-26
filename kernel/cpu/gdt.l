// GDT de 64 bits con TSS.
//
//   0x00 nulo
//   0x08 código kernel (64 bits, DPL 0)
//   0x10 datos kernel
//   0x18 datos usuario (DPL 3)   } orden que exige SYSRET
//   0x20 código usuario (DPL 3)  }
//   0x28 TSS (descriptor de 16 bytes)
//
// La TSS solo aporta pilas: RSP0 (para cuando haya modo usuario) e IST1,
// una pila aparte para la doble falta, así un desbordamiento de la pila
// del kernel no termina en triple falta.

take nucleo.cpu
take nucleo.mem

expose fixed SELECTOR_CODIGO = 0x08
expose fixed SELECTOR_DATOS = 0x10
expose fixed SELECTOR_TSS = 0x28

fixed TAMANO_PILA = 16384

flow tabla() => Int { give reservar(56, 16) }
flow registroGdt() => Int { give reservar(16, 16) }
flow tss() => Int { give reservar(104, 16) }
flow pilaDobleFalta() => Int { give reservar(TAMANO_PILA, 16) }
flow pilaAnillo0() => Int { give reservar(TAMANO_PILA, 16) }

expose flow gdtIniciar() {
    hold g = tabla()
    escribir64(g, 0)
    escribir64(g + 8, 0x00AF9A000000FFFF)
    escribir64(g + 16, 0x00CF92000000FFFF)
    escribir64(g + 24, 0x00CFF2000000FFFF)
    escribir64(g + 32, 0x00AFFA000000FFFF)

    // TSS: RSP0 en +4, IST1 en +36, base del mapa de E/S en +102 (= tamaño:
    // sin mapa de E/S).
    hold t = tss()
    each i among 0..13 { escribir64(t + i * 8, 0) }
    escribir64(t + 4, pilaAnillo0() + TAMANO_PILA)
    escribir64(t + 36, pilaDobleFalta() + TAMANO_PILA)
    escribir16(t + 102, 104)

    // Descriptor de sistema de 16 bytes: tipo 0x89 (TSS de 64 bits
    // disponible, presente), límite 103.
    hold limite = 103
    hold bajo = (limite & 0xFFFF) | ((t & 0xFFFFFF) << 16) | (0x89 << 40) | (((limite >> 16) & 0xF) << 48) | (((t >> 24) & 0xFF) << 56)
    escribir64(g + 40, bajo)
    escribir64(g + 48, (t >> 32) & 0xFFFFFFFF)

    hold r = registroGdt()
    escribir16(r, 56 - 1)
    escribir64(r + 2, g)
    lgdt(r)
    recargarSegmentos(SELECTOR_CODIGO, SELECTOR_DATOS)
    ltr(SELECTOR_TSS)
}

// En un procesador secundario: misma GDT, sin TSS (su descriptor ya está
// ocupado por el BSP).
expose flow gdtCargarEnAp() {
    lgdt(registroGdt())
    recargarSegmentos(SELECTOR_CODIGO, SELECTOR_DATOS)
}
