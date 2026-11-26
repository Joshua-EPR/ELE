// Memoria física: mapa de bits de marcos de 4 KiB.
//
// Un bit por marco hasta el final de la memoria usable más alta; 1 = ocupado.
// Se empieza con todo ocupado, se liberan las regiones USABLE del mapa de
// Limine y se vuelven a ocupar el marco 0 y los marcos del propio mapa de
// bits. Las regiones "recuperables del cargador" siguen ocupadas: allí
// están la pila actual y las respuestas de Limine.
//
// Todo acceso a memoria física pasa por el mapa directo (HHDM):
// virtual = física + memHhdm().

take nucleo.mem
take arranque.limine
take lib.consola

expose fixed MARCO = 4096

// Estado: +0 HHDM, +8 dirección física del mapa, +16 marcos totales,
// +24 marcos libres, +32 pista de búsqueda (primer marco quizá libre).
flow estado() => Int { give reservar(40, 8) }

expose flow memHhdm() => Int { give leer64(estado()) }

// Virtual (por el HHDM) de una dirección física.
expose flow memVirtual(fisica: Int) => Int { give fisica + leer64(estado()) }

expose flow memFisicaLibres() => Int { give leer64(estado() + 24) }
// Bytes del mapa de Limine de un tipo (MEMORIA_*).
expose flow memBytesDeTipo(tipo: Int) => Int {
    change total = 0
    each i among 0..arranqueMemoriaCantidad() {
        hold ent = arranqueMemoriaEntrada(i)
        when leer64(ent + 16) == tipo { total += leer64(ent + 8) }
    }
    give total
}

// RAM que gestiona el kernel: usable + recuperable del cargador + kernel.
// Lo reservado, ACPI, el framebuffer y los MMIO no son RAM disponible.
expose flow memFisicaTotalBytes() => Int {
    give memBytesDeTipo(MEMORIA_USABLE) + memBytesDeTipo(MEMORIA_CARGADOR_RECUPERABLE) + memBytesDeTipo(MEMORIA_KERNEL)
}

flow mapa() => Int { give memVirtual(leer64(estado() + 8)) }

flow ocupado(marco: Int) => Bool {
    hold b = leer8(mapa() + marco / 8)
    give b & (1 << (marco % 8)) != 0
}

flow marcar(marco: Int, usado: Bool) {
    hold dir = mapa() + marco / 8
    hold b = leer8(dir)
    hold bit = 1 << (marco % 8)
    hold antes = b & bit != 0
    when usado && !antes {
        escribir8(dir, b | bit)
        escribir64(estado() + 24, leer64(estado() + 24) - 1)
    }
    when !usado && antes {
        escribir8(dir, b & (~bit))
        escribir64(estado() + 24, leer64(estado() + 24) + 1)
    }
}

// false si Limine no dio HHDM o mapa de memoria, o no cabe el mapa de bits.
expose flow memFisicaIniciar() => Bool {
    hold e = estado()
    hold hhdm = arranqueHhdm()
    hold n = arranqueMemoriaCantidad()
    when hhdm == -1 || n == 0 { give false }
    escribir64(e, hhdm)

    // Final de la memoria gestionable más alta (usable o recuperable del
    // cargador, que se libera después) -> número de marcos.
    change fin = 0
    each i among 0..n {
        hold ent = arranqueMemoriaEntrada(i)
        hold tipo = leer64(ent + 16)
        when (tipo == MEMORIA_USABLE || tipo == MEMORIA_CARGADOR_RECUPERABLE) && leer64(ent) + leer64(ent + 8) > fin {
            fin = leer64(ent) + leer64(ent + 8)
        }
    }
    hold marcos = fin / MARCO
    hold bytes_mapa = (marcos + 7) / 8

    // El mapa va al principio de la primera región usable donde quepa.
    change sitio = -1
    each i among 0..n {
        hold ent = arranqueMemoriaEntrada(i)
        when sitio < 0 && leer64(ent + 16) == MEMORIA_USABLE && leer64(ent + 8) >= bytes_mapa && leer64(ent) >= MARCO {
            sitio = leer64(ent)
        }
    }
    when sitio < 0 { give false }
    escribir64(e + 8, sitio)
    escribir64(e + 16, marcos)
    escribir64(e + 24, 0)
    escribir64(e + 32, 0)

    // Todo ocupado (0xFF), luego se liberan las regiones usables.
    hold m = mapa()
    change k = 0
    during k + 8 <= bytes_mapa {
        escribir64(m + k, -1)
        k += 8
    }
    during k < bytes_mapa {
        escribir8(m + k, 0xFF)
        k += 1
    }
    each i among 0..n {
        hold ent = arranqueMemoriaEntrada(i)
        when leer64(ent + 16) == MEMORIA_USABLE {
            hold primero = (leer64(ent) + MARCO - 1) / MARCO
            hold ultimo = (leer64(ent) + leer64(ent + 8)) / MARCO
            each f among primero..ultimo { marcar(f, false) }
        }
    }
    marcar(0, true)
    hold primero_mapa = sitio / MARCO
    hold ultimo_mapa = (sitio + bytes_mapa + MARCO - 1) / MARCO
    each f among primero_mapa..ultimo_mapa { marcar(f, true) }
    give true
}

// Dirección física de un marco libre puesto a cero, o 0 si no queda.
expose flow memFisicaReservar() => Int {
    hold e = estado()
    hold total = leer64(e + 16)
    change f = leer64(e + 32)
    hold m = mapa()
    during f < total {
        // Salta de 64 en 64 marcos completamente ocupados.
        when f % 64 == 0 && f + 64 <= total && leer64(m + f / 8) == -1 {
            f += 64
        } otherwise {
            when !ocupado(f) {
                marcar(f, true)
                escribir64(e + 32, f + 1)
                hold v = memVirtual(f * MARCO)
                each i among 0..512 { escribir64(v + i * 8, 0) }
                give f * MARCO
            }
            f += 1
        }
    }
    give 0
}

expose flow memFisicaLiberar(fisica: Int) {
    hold f = fisica / MARCO
    when f <= 0 || f >= leer64(estado() + 16) { give }
    marcar(f, false)
    when f < leer64(estado() + 32) { escribir64(estado() + 32, f) }
}

// Marco libre por debajo de 1 MiB (para el trampolín SMP), o 0.
expose flow memFisicaReservarBajo() => Int {
    each f among 1..256 {
        when f < leer64(estado() + 16) && !ocupado(f) {
            marcar(f, true)
            give f * MARCO
        }
    }
    give 0
}

// Libera la memoria "recuperable del cargador" una vez copiadas las
// respuestas de Limine (arranqueCopiar) y cargado el PML4 propio. Se
// conservan los marcos a menos de 64 KiB de la pila de arranque (la pila
// del BSP sigue allí). Devuelve los bytes liberados.
expose flow memFisicaRecuperarCargador(pila: Int) => Int {
    hold pila_fisica = pila - memHhdm()
    hold guarda_inicio = (pila_fisica - 65536) / MARCO
    hold guarda_fin = (pila_fisica + 65536) / MARCO
    change liberados = 0
    each i among 0..arranqueMemoriaCantidad() {
        hold ent = arranqueMemoriaEntrada(i)
        when leer64(ent + 16) == MEMORIA_CARGADOR_RECUPERABLE {
            hold primero = (leer64(ent) + MARCO - 1) / MARCO
            hold ultimo = (leer64(ent) + leer64(ent + 8)) / MARCO
            each f among primero..ultimo {
                when (f < guarda_inicio || f > guarda_fin) && f < leer64(estado() + 16) && ocupado(f) {
                    marcar(f, false)
                    liberados += MARCO
                }
            }
        }
    }
    escribir64(estado() + 32, 0)
    give liberados
}

// Diagnóstico: el mapa de memoria copiado de Limine, cuatro entradas por
// línea (tipo:base+KiB).
expose flow memImprimirMapa() {
    hold n = arranqueMemoriaCantidad()
    each i among 0..n {
        hold ent = arranqueMemoriaEntrada(i)
        kprintEntero(leer64(ent + 16))
        kprintByte(58)
        kprintHex(leer64(ent))
        kprintByte(43)
        kprintEntero(leer64(ent + 8) / 1024)
        when i % 3 == 2 { kprintByte(10) } otherwise { kprintByte(32) }
    }
    kprintByte(10)
}
