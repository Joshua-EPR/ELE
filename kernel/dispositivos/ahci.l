// Controlador SATA AHCI: lectura y escritura de sectores (512 bytes) por
// DMA, por sondeo (sin interrupciones todavía).
//
// Cada puerto con disco usa un marco físico propio:
//   +0     lista de órdenes (32 entradas de 32 bytes; solo se usa la 0)
//   +1024  FIS recibidos (256 bytes)
//   +2048  tabla de la orden 0: FIS H2D (+0), PRDT (+0x80, hasta 120
//          entradas de 16 bytes)
// Los datos van a búferes del montón: cada página de 4 KiB cuenta como una
// entrada de la PRDT (su física se obtiene con pagTraducir), pero las
// páginas contiguas en la memoria física se funden en una sola entrada (hasta
// 4 MiB), así que una orden mueve hasta 8 MiB (AHCI_MAX_SECTORES). Si la
// PRDT se llena antes, la orden cubre menos y ahciLeer/ahciEscribir siguen
// con otra orden.
//
// Este módulo NO decide qué se puede escribir: almacenamiento/disco.l
// comprueba la partición antes de llamar a ahciEscribir.

take nucleo.cpu
take nucleo.mem
take cpu.ifdiag
take mem.fisica
take mem.paginacion
take dispositivos.pci
take tiempo.reloj

expose fixed SECTOR = 512
expose fixed AHCI_MAX_SECTORES = 16384    // 8 MiB por orden (LBA48: hasta 65535)
fixed MAX_PUERTOS = 32
fixed MAX_PRD = 120                       // entradas de la PRDT en el marco del puerto
fixed MAX_PRD_BYTES = 0x400000            // 4 MiB por entrada

// Registros del HBA y de cada puerto.
fixed HBA_GHC = 0x04
fixed HBA_PI = 0x0C
fixed HBA_VS = 0x10
fixed P_CLB = 0x00
fixed P_CLBU = 0x04
fixed P_FB = 0x08
fixed P_FBU = 0x0C
fixed P_IS = 0x10
fixed P_IE = 0x14
fixed P_CMD = 0x18
fixed P_TFD = 0x20
fixed P_SIG = 0x24
fixed P_SSTS = 0x28
fixed P_SERR = 0x30
fixed P_CI = 0x38

// Estado: +0 ABAR virtual, +8 versión, +16 discos, +24.. por disco (hasta
// 8) 32 bytes: +0 puerto, +8 marco físico, +16 sectores, +24 libre.
// +280.. modelo del último IDENTIFY (40 bytes).
flow estado() => Int { give reservar(328, 8) }

expose flow ahciDiscos() => Int { give leer64(estado() + 16) }
expose flow ahciSectores(disco: Int) => Int { give leer64(estado() + 24 + disco * 32 + 16) }
expose flow ahciPuerto(disco: Int) => Int { give leer64(estado() + 24 + disco * 32) }
expose flow ahciVersion() => Int { give leer64(estado() + 8) }
expose flow ahciModelo() => Int { give estado() + 280 }

flow puerto(p: Int) => Int { give leer64(estado()) + 0x100 + p * 0x80 }

flow esperarBits(dir: Int, mascara: Int, valor: Int, us: Int) => Bool {
    hold inicio = relojNanosegundos()
    during leer32(dir) & mascara != valor {
        when relojNanosegundos() - inicio > us * 1000 { give false }
        pause()
    }
    give true
}

flow detener(r: Int) {
    escribir32(r + P_CMD, leer32(r + P_CMD) & (~0x11))
    hold parado = esperarBits(r + P_CMD, 0xC000, 0, 500000)
}

flow arrancar(r: Int) {
    hold listo = esperarBits(r + P_TFD, 0x88, 0, 1000000)
    escribir32(r + P_CMD, leer32(r + P_CMD) | 0x10)
    escribir32(r + P_CMD, leer32(r + P_CMD) | 0x01)
}

// Prepara el puerto `p` y lo añade como disco. false si falla.
flow prepararPuerto(p: Int) => Bool {
    hold e = estado()
    hold n = leer64(e + 16)
    when n >= 8 { give false }
    hold r = puerto(p)
    hold marco = memFisicaReservar()
    when marco == 0 { give false }
    detener(r)
    escribir32(r + P_CLB, marco & 0xFFFFFFFF)
    escribir32(r + P_CLBU, marco >> 32)
    escribir32(r + P_FB, (marco + 1024) & 0xFFFFFFFF)
    escribir32(r + P_FBU, (marco + 1024) >> 32)
    escribir32(r + P_SERR, 0xFFFFFFFF)
    escribir32(r + P_IS, 0xFFFFFFFF)
    escribir32(r + P_IE, 0)
    arrancar(r)
    hold d = e + 24 + n * 32
    escribir64(d, p)
    escribir64(d + 8, marco)
    escribir64(d + 16, 0)
    escribir64(e + 16, n + 1)
    give true
}

// ---- órdenes ---------------------------------------------------------------

// Orden ATA `orden_ata` con LBA de 48 bits sobre hasta `sectores` sectores en
// el búfer `dir` (virtual, mapeado). escritura = el HBA lee del búfer.
// Devuelve los sectores que cubrió la orden (puede ser menos si la PRDT se
// llenó), 0 si no hay datos (p. ej. FLUSH) o -1 si falló.
flow ordenTrozo(disco: Int, orden_ata: Int, lba: Int, sectores: Int, dir: Int, escritura: Bool) => Int {
    hold e = estado()
    hold d = e + 24 + disco * 32
    hold r = puerto(leer64(d))
    hold marco = leer64(d + 8)
    hold v = memVirtual(marco)
    hold tabla = v + 2048
    // PRDT: una entrada por página (o trozo de página) del búfer; las
    // contiguas en la memoria física se funden (hasta 4 MiB por entrada).
    change entradas = 0
    change hecho = 0
    hold limite = sectores * SECTOR
    change ultimaFisica = 0
    change ultimoBytes = 0
    during hecho < limite {
        hold virtual = dir + hecho
        hold fisica = pagTraducir(virtual)
        when fisica < 0 { give -1 }
        change trozo = 4096 - (virtual & 0xFFF)
        when trozo > limite - hecho { trozo = limite - hecho }
        when entradas > 0 && fisica == ultimaFisica + ultimoBytes && ultimoBytes + trozo <= MAX_PRD_BYTES {
            ultimoBytes += trozo
            escribir32(tabla + 0x80 + (entradas - 1) * 16 + 12, ultimoBytes - 1)
        } otherwise {
            when entradas >= MAX_PRD { leave }
            hold prd = tabla + 0x80 + entradas * 16
            escribir32(prd, fisica & 0xFFFFFFFF)
            escribir32(prd + 4, fisica >> 32)
            escribir32(prd + 8, 0)
            escribir32(prd + 12, trozo - 1)
            ultimaFisica = fisica
            ultimoBytes = trozo
            entradas += 1
        }
        hecho += trozo
    }
    // Si la PRDT se llenó, se recorta al último sector completo.
    change sobrante = hecho % SECTOR
    during sobrante > 0 {
        hold prd = tabla + 0x80 + (entradas - 1) * 16
        hold tam = leer32(prd + 12) + 1
        when tam > sobrante {
            escribir32(prd + 12, tam - sobrante - 1)
            hecho -= sobrante
            sobrante = 0
        } otherwise {
            entradas -= 1
            hecho -= tam
            sobrante -= tam
        }
    }
    hold cubiertos = hecho / SECTOR
    when sectores > 0 && cubiertos < 1 { give -1 }
    // FIS H2D (registro, de anfitrión a dispositivo).
    each i among 0..16 { escribir32(tabla + i * 4, 0) }
    escribir8(tabla, 0x27)
    escribir8(tabla + 1, 0x80)
    escribir8(tabla + 2, orden_ata)
    escribir8(tabla + 4, lba & 0xFF)
    escribir8(tabla + 5, (lba >> 8) & 0xFF)
    escribir8(tabla + 6, (lba >> 16) & 0xFF)
    escribir8(tabla + 7, 0x40)
    escribir8(tabla + 8, (lba >> 24) & 0xFF)
    escribir8(tabla + 9, (lba >> 32) & 0xFF)
    escribir8(tabla + 10, (lba >> 40) & 0xFF)
    escribir8(tabla + 12, cubiertos & 0xFF)
    escribir8(tabla + 13, (cubiertos >> 8) & 0xFF)
    // Cabecera de la orden 0: FIS de 5 palabras, W, PRDTL.
    change cabecera = 5 | (entradas << 16)
    when escritura { cabecera = cabecera | 0x40 }
    escribir32(v, cabecera)
    escribir32(v + 4, 0)
    escribir32(v + 8, (marco + 2048) & 0xFFFFFFFF)
    escribir32(v + 12, (marco + 2048) >> 32)
    escribir32(r + P_IS, 0xFFFFFFFF)
    when !esperarBits(r + P_TFD, 0x88, 0, 1000000) { give -1 }
    escribir32(r + P_CI, 1)
    hold inicio = relojNanosegundos()
    during leer32(r + P_CI) & 1 != 0 {
        // IS.TFES (bit 30): error de archivo de tareas.
        when leer32(r + P_IS) & 0x40000000 != 0 { give -1 }
        when relojNanosegundos() - inicio > 10000000000 { give -1 }
        pause()
    }
    when leer32(r + P_TFD) & 0x01 != 0 { give -1 }
    give cubiertos
}

// Orden de un solo trozo (IDENTIFY, FLUSH, ...): true si cubrió todo.
flow orden(disco: Int, orden_ata: Int, lba: Int, sectores: Int, dir: Int, escritura: Bool) => Bool {
    hold n = ordenTrozo(disco, orden_ata, lba, sectores, dir, escritura)
    when n < 0 { give false }
    give n == sectores
}

// Transferencia de `sectores` sectores en tantas órdenes como hagan falta.
flow transferir(disco: Int, orden_ata: Int, lba: Int, sectores: Int, dir: Int, escritura: Bool) => Bool {
    when sectores < 1 { give false }
    change hecho = 0
    during hecho < sectores {
        change t = sectores - hecho
        when t > AHCI_MAX_SECTORES { t = AHCI_MAX_SECTORES }
        ifVigilar(cadena("ahciA"))
        hold n = ordenTrozo(disco, orden_ata, lba + hecho, t, dir + hecho * SECTOR, escritura)
        ifVigilar(cadena("ahciB"))
        when n < 1 { give false }
        hecho += n
    }
    give true
}

// IDENTIFY DEVICE: sectores (LBA48) y modelo. false si no responde.
flow identificar(disco: Int) => Bool {
    hold marco = memFisicaReservar()
    when marco == 0 { give false }
    hold buf = memVirtual(marco)
    hold bien = orden(disco, 0xEC, 0, 1, buf, false)
    when bien {
        hold d = estado() + 24 + disco * 32
        escribir64(d + 16, leer64(buf + 200))
        // Modelo: palabras 27..46, cada una con los bytes intercambiados.
        hold modelo = ahciModelo()
        each i among 0..20 {
            escribir8(modelo + i * 2, leer8(buf + 54 + i * 2 + 1))
            escribir8(modelo + i * 2 + 1, leer8(buf + 54 + i * 2))
        }
    }
    memFisicaLiberar(marco)
    give bien
}

// Busca el primer controlador AHCI por PCI, lo activa y prepara cada
// puerto con un disco SATA. Devuelve el número de discos.
expose flow ahciIniciar() => Int {
    hold e = estado()
    escribir64(e + 16, 0)
    hold i = pciDisco()
    when i < 0 { give 0 }
    hold ent = pciEntrada(i)
    when pciTipoDisco(leer64(ent + 16)) != DISCO_AHCI { give 0 }
    hold bdf = leer64(ent)
    pciHabilitarDma(bdf)
    hold abar_fisica = pciLeer32(bdf, 0x24) & (~0xFFF)
    hold abar = pagMapearDispositivo(abar_fisica)
    hold segunda = pagMapearDispositivo(abar_fisica + 0x1000)
    escribir64(e, abar)
    escribir64(e + 8, leer32(abar + HBA_VS))
    // GHC.AE: modo AHCI.
    escribir32(abar + HBA_GHC, leer32(abar + HBA_GHC) | 0x80000000)
    hold implementados = leer32(abar + HBA_PI)
    each p among 0..MAX_PUERTOS {
        when (implementados >> p) & 1 == 1 {
            hold r = puerto(p)
            // DET = 3 (dispositivo y enlace) y firma de disco ATA.
            when leer32(r + P_SSTS) & 0xF == 3 && leer32(r + P_SIG) == 0x101 {
                hold n = leer64(e + 16)
                when prepararPuerto(p) {
                    when !identificar(n) { escribir64(e + 16, n) }
                }
            }
        }
    }
    give leer64(e + 16)
}

// Lee `sectores` desde `lba` al búfer `dir` (en órdenes de hasta 8 MiB).
expose flow ahciLeer(disco: Int, lba: Int, sectores: Int, dir: Int) => Bool {
    give transferir(disco, 0x25, lba, sectores, dir, false)
}

// Escribe sin comprobar nada: solo para almacenamiento/disco.l.
expose flow ahciEscribir(disco: Int, lba: Int, sectores: Int, dir: Int) => Bool {
    give transferir(disco, 0x35, lba, sectores, dir, true)
}

// FLUSH CACHE EXT: el disco escribe en el medio lo que tenga en su caché.
expose flow ahciVaciar(disco: Int) => Bool {
    give orden(disco, 0xEA, 0, 0, 0, false)
}
