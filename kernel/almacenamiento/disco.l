// Disco con tabla GPT y escritura protegida.
//
// REGLA DE SEGURIDAD: el disco de la laptop puede tener datos. Este módulo
// solo escribe dentro de UNA partición marcada para este sistema:
//   - GUID de tipo 7F03465A-8D62-4902-B881-2A624BFA16B6 ("datos ELE"), o
//   - o partición de datos Microsoft formateada en FAT32 con la etiqueta de
//     volumen "ELEDATOS" (la firma está en su primer sector: así se puede
//     preparar desde Windows con diskpart y copiarle archivos).
// Cualquier escritura fuera de ella llama a panico(). Sin partición
// marcada, el disco es de solo lectura.

take nucleo.mem
take mem.monton
take dispositivos.ahci
take lib.consola
take lib.panico

// Tipos de partición conocidos (GUID en el orden de bytes del disco, como
// dos palabras little-endian).
fixed ELE_BAJO = 0x49028D627F03465A
fixed ELE_ALTO = 0xB616FA4B622A81B8
fixed EFI_BAJO = 0x11D2F81FC12A7328
fixed EFI_ALTO = 0x3BC93EC9A0004BBA
fixed MSDATOS_BAJO = 0x4433B9E5EBD0A0A2
fixed MSDATOS_ALTO = 0xC79926B7B668C087
fixed MSRES_BAJO = 0x4DB80B5CE3C9E316
fixed MSRES_ALTO = 0xAE1502F02DF97D81
fixed WINRE_BAJO = 0x4D4006D1DE94BBA4
fixed WINRE_ALTO = 0xACD67901D5BF6AA1
fixed LINUX_BAJO = 0x477284830FC63DAF
fixed LINUX_ALTO = 0xE47D47D8693D798E
fixed BIOSBOOT_BAJO = 0x6E6F644921686148
fixed BIOSBOOT_ALTO = 0x4946456465654E74
fixed SWAP_BAJO = 0x43C4A4AB0657FD6D
fixed SWAP_ALTO = 0x4F4F4BC83309E584
fixed LVM_BAJO = 0x44C2F507E6D6D379
fixed LVM_ALTO = 0x28F93D2A8F233CA2
fixed FIRMA_GPT = 0x5452415020494645     // "EFI PART"

// Estado: +0 disco, +8 hay partición permitida (1/0), +16 primer LBA,
// +24 último LBA, +32 número de partición, +40 búfer de 1 sector,
// +48 escritura habilitada (1/0).
flow estado() => Int { give reservar(56, 8) }

expose flow discoPermitidoPrimero() => Int { give leer64(estado() + 16) }
expose flow discoPermitidoUltimo() => Int { give leer64(estado() + 24) }
expose flow discoHayPermitida() => Bool { give leer64(estado() + 8) == 1 }
expose flow discoActual() => Int { give leer64(estado()) }

flow sector() => Int {
    hold e = estado()
    when leer64(e + 40) == 0 { escribir64(e + 40, montonReservar(512)) }
    give leer64(e + 40)
}

flow tipo(entrada: Int) => Int {
    hold bajo = leer64(entrada)
    hold alto = leer64(entrada + 8)
    when bajo == ELE_BAJO && alto == ELE_ALTO { give 1 }
    when bajo == EFI_BAJO && alto == EFI_ALTO { give 2 }
    when bajo == MSDATOS_BAJO && alto == MSDATOS_ALTO { give 3 }
    when bajo == MSRES_BAJO && alto == MSRES_ALTO { give 4 }
    when bajo == WINRE_BAJO && alto == WINRE_ALTO { give 5 }
    when bajo == LINUX_BAJO && alto == LINUX_ALTO { give 6 }
    when bajo == BIOSBOOT_BAJO && alto == BIOSBOOT_ALTO { give 7 }
    when bajo == SWAP_BAJO && alto == SWAP_ALTO { give 8 }
    when bajo == LVM_BAJO && alto == LVM_ALTO { give 9 }
    give 0
}

flow nombreTipo(t: Int) => Int {
    when t == 1 { give cadena("DATOS ELE") }
    when t == 2 { give cadena("sistema EFI") }
    when t == 3 { give cadena("datos Microsoft") }
    when t == 4 { give cadena("reservada Microsoft") }
    when t == 5 { give cadena("recuperación Windows") }
    when t == 6 { give cadena("Linux") }
    when t == 7 { give cadena("arranque BIOS (GRUB)") }
    when t == 8 { give cadena("intercambio Linux") }
    when t == 9 { give cadena("LVM Linux") }
    give cadena("otro tipo")
}

flow tieneFirma(disco: Int, lba: Int) => Bool {
    hold s = sector()
    when !ahciLeer(disco, lba, 1, s) { give false }
    // Sector de arranque FAT32: tipo "FAT32   " (+82) y etiqueta
    // "ELEDATOS   " (+71), y la firma 0x55AA.
    give leer64(s + 82) == 0x2020203233544146 && leer64(s + 71) == 0x534F544144454C45 && leer8(s + 79) == 32 && leer16(s + 510) == 0xAA55
}

flow imprimirEntrada(ent: Int, i: Int, t: Int, primero: Int, ultimo: Int) {
    kprint(cadena("       "))
    kprintEntero(i + 1)
    kprint(cadena("  "))
    kprint(nombreTipo(t))
    kprint(cadena("  "))
    kprintEntero(primero)
    kprint(cadena(" - "))
    kprintEntero(ultimo)
    kprint(cadena("  "))
    kprintEntero((ultimo - primero + 1) / 2048)
    kprint(cadena(" MiB  "))
    // Nombre UTF-16: se muestran los caracteres < U+0100.
    change c = 0
    during c < 36 && leer16(ent + 56 + c * 2) != 0 {
        hold u = leer16(ent + 56 + c * 2)
        when u < 0x100 { kprintCaracter(u) } otherwise { kprintByte(63) }
        c += 1
    }
    kprintByte(10)
}

// Lee la GPT del disco, la imprime entera (si `imprimir`) y busca la
// partición permitida. false si el disco no tiene GPT válida.
expose flow discoAbrir(disco: Int, imprimir: Bool) => Bool {
    hold e = estado()
    escribir64(e, disco)
    escribir64(e + 8, 0)
    escribir64(e + 48, 0)
    hold cabecera = montonReservar(512)
    when !ahciLeer(disco, 1, 1, cabecera) || leer64(cabecera) != FIRMA_GPT {
        montonLiberar(cabecera)
        give false
    }
    hold lba_entradas = leer64(cabecera + 72)
    hold cantidad = leer32(cabecera + 80)
    hold tamano = leer32(cabecera + 84)
    montonLiberar(cabecera)
    when tamano < 128 || cantidad > 256 { give false }
    hold bytes = cantidad * tamano
    hold sectores = (bytes + 511) / 512
    hold tabla = montonReservar(sectores * 512)
    when !ahciLeer(disco, lba_entradas, sectores, tabla) {
        montonLiberar(tabla)
        give false
    }
    when imprimir { kprintln(cadena("  GPT:  n  tipo                  primer LBA  último LBA     MiB  nombre")) }
    each i among 0..cantidad {
        hold ent = tabla + i * tamano
        when leer64(ent) != 0 || leer64(ent + 8) != 0 {
            hold t = tipo(ent)
            hold primero = leer64(ent + 32)
            hold ultimo = leer64(ent + 40)
            when imprimir { imprimirEntrada(ent, i, t, primero, ultimo) }
            change marcada = t == 1
            when !marcada && t == 3 { marcada = tieneFirma(disco, primero) }
            when marcada && leer64(e + 8) == 0 && ultimo >= primero {
                escribir64(e + 8, 1)
                escribir64(e + 16, primero)
                escribir64(e + 24, ultimo)
                escribir64(e + 32, i + 1)
            }
        }
    }
    montonLiberar(tabla)
    give true
}

// ¿Está [lba, lba + sectores) entero dentro de la partición permitida?
expose flow discoEscrituraPermitida(lba: Int, sectores: Int) => Bool {
    hold e = estado()
    when leer64(e + 8) != 1 || sectores < 1 { give false }
    give lba >= leer64(e + 16) && lba + sectores - 1 <= leer64(e + 24)
}

// Habilita la escritura (después de mostrar la GPT). false si no hay
// partición permitida.
expose flow discoHabilitarEscritura() => Bool {
    hold e = estado()
    when leer64(e + 8) != 1 { give false }
    escribir64(e + 48, 1)
    give true
}

// Lectura de `sectores` sectores (el controlador la parte en órdenes de 8 MiB).
expose flow discoLeer(lba: Int, sectores: Int, dir: Int) => Bool {
    give ahciLeer(discoActual(), lba, sectores, dir)
}

// Escritura protegida: fuera de la partición permitida, o sin habilitar,
// es un pánico (nunca un error silencioso). Se comprueba el rango entero
// antes de la primera orden.
expose flow discoEscribir(lba: Int, sectores: Int, dir: Int) => Bool {
    when leer64(estado() + 48) != 1 { panico(cadena("escritura de disco sin habilitar")) }
    when !discoEscrituraPermitida(lba, sectores) { panico(cadena("escritura fuera de la partición ELE")) }
    give ahciEscribir(discoActual(), lba, sectores, dir)
}

// Asegura que todo lo escrito está en el medio (caché del disco vaciada).
expose flow discoVaciar() => Bool {
    give ahciVaciar(discoActual())
}
