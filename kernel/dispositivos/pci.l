// PCI Express por ECAM (tabla MCFG de ACPI).
//
// El espacio de configuración de la función bus:disp.fn está en
// ECAM + (bus << 20 | disp << 15 | fn << 12), 4 KiB por función, y se lee
// con accesos normales a memoria (mapeados sin caché). Las funciones se
// identifican con bdf = bus << 8 | disp << 3 | fn.

take nucleo.mem
take mem.fisica
take mem.paginacion
take dispositivos.acpi
take lib.consola

fixed MAX_FUNCIONES = 128

// Estado: +0 funciones encontradas, +8.. una entrada de 32 bytes por
// función: +0 bdf, +8 fabricante | dispositivo << 16, +16 clase << 16 |
// subclase << 8 | interfaz, +24 tipo de cabecera.
flow estado() => Int { give reservar(8 + MAX_FUNCIONES * 32, 8) }

expose flow pciCantidad() => Int { give leer64(estado()) }
expose flow pciEntrada(i: Int) => Int { give estado() + 8 + i * 32 }

expose flow pciBdf(bus: Int, disp: Int, fn: Int) => Int {
    give (bus << 8) | (disp << 3) | fn
}

// Dirección virtual del espacio de configuración de `bdf` (lo mapea).
expose flow pciConfig(bdf: Int) => Int {
    hold fisica = acpiEcamFisica() + (bdf << 12)
    give pagMapearDispositivo(fisica)
}

expose flow pciLeer8(bdf: Int, desp: Int) => Int { give leer8(pciConfig(bdf) + desp) }
expose flow pciLeer16(bdf: Int, desp: Int) => Int { give leer16(pciConfig(bdf) + desp) }
expose flow pciLeer32(bdf: Int, desp: Int) => Int { give leer32(pciConfig(bdf) + desp) }
expose flow pciEscribir16(bdf: Int, desp: Int, valor: Int) { escribir16(pciConfig(bdf) + desp, valor) }
expose flow pciEscribir32(bdf: Int, desp: Int, valor: Int) { escribir32(pciConfig(bdf) + desp, valor) }

flow anotar(bdf: Int) {
    hold e = estado()
    hold n = leer64(e)
    when n >= MAX_FUNCIONES { give }
    hold ent = e + 8 + n * 32
    hold v = pciConfig(bdf)
    escribir64(ent, bdf)
    escribir64(ent + 8, leer32(v))
    escribir64(ent + 16, leer32(v + 8) >> 8)
    escribir64(ent + 24, leer8(v + 14))
    escribir64(e, n + 1)
}

// Recorre todos los buses de la MCFG. false si no hay ECAM.
expose flow pciEnumerar() => Bool {
    escribir64(estado(), 0)
    when acpiEcamFisica() == 0 { give false }
    each bus among acpiPrimerBus()..(acpiUltimoBus() + 1) {
        each disp among 0..32 {
            hold bdf0 = pciBdf(bus, disp, 0)
            when pciLeer16(bdf0, 0) != 0xFFFF {
                anotar(bdf0)
                // Bit 7 del tipo de cabecera: dispositivo multifunción.
                when pciLeer8(bdf0, 14) & 0x80 != 0 {
                    each fn among 1..8 {
                        hold bdf = pciBdf(bus, disp, fn)
                        when pciLeer16(bdf, 0) != 0xFFFF { anotar(bdf) }
                    }
                }
            }
        }
    }
    give true
}

// ---- BAR -------------------------------------------------------------------

// BAR `n` (0..5) de una cabecera de tipo 0: dirección y tamaño. Para medir
// el tamaño se apaga la decodificación (registro de órdenes) mientras se
// escribe ~0, y se restaura todo. Devuelve el tamaño; la dirección queda en
// pciBarDireccion (0 si el BAR no existe o es la mitad alta de uno de 64).
flow barEstado() => Int { give reservar(16, 8) }
expose flow pciBarDireccion() => Int { give leer64(barEstado()) }
expose flow pciBarEsEs() => Bool { give leer64(barEstado() + 8) == 1 }

expose flow pciBarMedir(bdf: Int, n: Int) => Int {
    hold v = pciConfig(bdf)
    hold reg = v + 0x10 + n * 4
    hold original = leer32(reg)
    escribir64(barEstado(), 0)
    escribir64(barEstado() + 8, 0)
    hold ordenes = leer16(v + 4)
    escribir16(v + 4, ordenes & (~0x3))
    escribir32(reg, 0xFFFFFFFF)
    hold sondeo = leer32(reg)
    escribir32(reg, original)
    change tamano = 0
    change direccion = 0
    when original & 1 == 1 {
        // E/S: 16 bits útiles.
        escribir64(barEstado() + 8, 1)
        direccion = original & (~0x3)
        hold mascara = (sondeo & (~0x3)) | 0xFFFF0000
        tamano = ((~mascara) & 0xFFFFFFFF) + 1
    } otherwise {
        direccion = original & (~0xF)
        change mascara = sondeo & (~0xF)
        when (original >> 1) & 3 == 2 && n < 5 {
            // 64 bits: la mitad alta en el BAR siguiente.
            hold alto_reg = reg + 4
            hold alto = leer32(alto_reg)
            escribir32(alto_reg, 0xFFFFFFFF)
            hold sondeo_alto = leer32(alto_reg)
            escribir32(alto_reg, alto)
            direccion = direccion | (alto << 32)
            mascara = mascara | (sondeo_alto << 32)
            tamano = (~mascara) + 1
        } otherwise {
            when mascara != 0 { tamano = ((~mascara) & 0xFFFFFFFF) + 1 }
        }
    }
    escribir16(v + 4, ordenes)
    when sondeo == 0 { tamano = 0 }
    escribir64(barEstado(), direccion)
    give tamano
}

// ---- capacidades, DMA y MSI ------------------------------------------------

// Desplazamiento de la capacidad `id` (0x05 MSI, 0x10 PCIe, 0x11 MSI-X),
// o 0.
expose flow pciCapacidad(bdf: Int, id: Int) => Int {
    when pciLeer16(bdf, 6) & 0x10 == 0 { give 0 }
    change p = pciLeer8(bdf, 0x34) & 0xFC
    change pasos = 0
    during p != 0 && pasos < 48 {
        when pciLeer8(bdf, p) == id { give p }
        p = pciLeer8(bdf, p + 1) & 0xFC
        pasos += 1
    }
    give 0
}

// Decodificación de memoria y bus mastering (DMA) activados.
expose flow pciHabilitarDma(bdf: Int) {
    pciEscribir16(bdf, 4, pciLeer16(bdf, 4) | 0x6)
}

// MSI: el dispositivo escribirá `vector` en el LAPIC `destino`. Desactiva
// las interrupciones INTx. false si no tiene MSI.
expose flow pciConfigurarMsi(bdf: Int, vector: Int, destino: Int) => Bool {
    hold cap = pciCapacidad(bdf, 0x05)
    when cap == 0 { give false }
    hold control = pciLeer16(bdf, cap + 2)
    pciEscribir32(bdf, cap + 4, 0xFEE00000 | (destino << 12))
    change datos = cap + 8
    when control & 0x80 != 0 {
        // Dirección de 64 bits: la parte alta, 0.
        pciEscribir32(bdf, cap + 8, 0)
        datos = cap + 12
    }
    pciEscribir16(bdf, datos, vector)
    // Un solo mensaje (bits 6:4 = 0) y MSI activo.
    pciEscribir16(bdf, cap + 2, (control & (~0x70)) | 1)
    pciEscribir16(bdf, 4, pciLeer16(bdf, 4) | 0x400)
    give true
}

// ---- controlador de disco --------------------------------------------------

expose fixed DISCO_NINGUNO = 0
expose fixed DISCO_AHCI = 1
expose fixed DISCO_NVME = 2
expose fixed DISCO_RAID = 3
expose fixed DISCO_IDE = 4

// Tipo de un código de clase (clase << 16 | subclase << 8 | interfaz).
expose flow pciTipoDisco(clase: Int) => Int {
    when clase >> 16 != 1 { give DISCO_NINGUNO }
    hold sub = (clase >> 8) & 0xFF
    when sub == 6 && clase & 0xFF == 1 { give DISCO_AHCI }
    when sub == 8 && clase & 0xFF == 2 { give DISCO_NVME }
    when sub == 4 { give DISCO_RAID }
    when sub == 1 { give DISCO_IDE }
    give DISCO_NINGUNO
}

// Índice (en la tabla de funciones) del primer controlador de disco
// reconocido, o -1.
expose flow pciDisco() => Int {
    each i among 0..pciCantidad() {
        when pciTipoDisco(leer64(pciEntrada(i) + 16)) != DISCO_NINGUNO { give i }
    }
    give -1
}

// ---- informe ---------------------------------------------------------------

flow hex(valor: Int, cifras: Int) {
    each i among 0..cifras {
        hold c = (valor >> (4 * (cifras - 1 - i))) & 0xF
        when c < 10 { kprintByte(48 + c) } otherwise { kprintByte(87 + c) }
    }
}

flow nombreClase(clase: Int) => Int {
    hold c = clase >> 16
    hold sub = (clase >> 8) & 0xFF
    when pciTipoDisco(clase) == DISCO_AHCI { give cadena("SATA AHCI") }
    when pciTipoDisco(clase) == DISCO_NVME { give cadena("NVMe") }
    when pciTipoDisco(clase) == DISCO_RAID { give cadena("RAID (¿Intel RST?)") }
    when c == 1 { give cadena("almacenamiento") }
    when c == 2 { give cadena("red") }
    when c == 3 { give cadena("pantalla") }
    when c == 4 { give cadena("multimedia") }
    when c == 5 { give cadena("memoria") }
    when c == 6 && sub == 0 { give cadena("puente anfitrión") }
    when c == 6 && sub == 1 { give cadena("puente ISA/LPC") }
    when c == 6 && sub == 4 { give cadena("puente PCI") }
    when c == 6 { give cadena("puente") }
    when c == 7 { give cadena("comunicación") }
    when c == 8 { give cadena("periférico del sistema") }
    when c == 0x0C && sub == 3 && clase & 0xFF == 0x30 { give cadena("USB xHCI") }
    when c == 0x0C && sub == 3 { give cadena("USB") }
    when c == 0x0C && sub == 5 { give cadena("SMBus") }
    when c == 0x0C { give cadena("bus serie") }
    when c == 0x0D { give cadena("inalámbrico") }
    when c == 0x11 { give cadena("adquisición de señal") }
    give cadena("otro")
}

// Una línea por función: bb:dd.f fabricante:dispositivo clase nombre, y sus
// BAR (m = memoria, e = E/S; dirección y tamaño en KiB).
expose flow pciImprimir() {
    each i among 0..pciCantidad() {
        hold ent = pciEntrada(i)
        hold bdf = leer64(ent)
        hold id = leer64(ent + 8)
        hold clase = leer64(ent + 16)
        kprint(cadena("  "))
        hex(bdf >> 8, 2)
        kprintByte(58)
        hex((bdf >> 3) & 31, 2)
        kprintByte(46)
        hex(bdf & 7, 1)
        kprintByte(32)
        hex(id & 0xFFFF, 4)
        kprintByte(58)
        hex(id >> 16, 4)
        kprintByte(32)
        hex(clase, 6)
        kprintByte(32)
        kprint(nombreClase(clase))
        when leer64(ent + 24) & 0x7F == 0 {
            change n = 0
            during n < 6 {
                hold tamano = pciBarMedir(bdf, n)
                hold dir = pciBarDireccion()
                hold es_es = pciBarEsEs()
                when tamano > 0 {
                    kprint(cadena(" BAR"))
                    kprintEntero(n)
                    when es_es { kprintByte(101) } otherwise { kprintByte(109) }
                    kprintByte(61)
                    hex(dir, 10)
                    kprintByte(47)
                    when tamano >= 1024 {
                        kprintEntero(tamano / 1024)
                        kprintByte(75)
                    } otherwise {
                        kprintEntero(tamano)
                    }
                }
                // Un BAR de memoria de 64 bits ocupa dos registros.
                hold original = pciLeer32(bdf, 0x10 + n * 4)
                when original & 1 == 0 && (original >> 1) & 3 == 2 { n += 1 }
                n += 1
            }
        }
        when pciCapacidad(bdf, 0x05) != 0 { kprint(cadena(" MSI")) }
        when pciCapacidad(bdf, 0x11) != 0 { kprint(cadena(" MSI-X")) }
        kprintByte(10)
    }
}
