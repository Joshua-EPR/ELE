// Checkpoints a prueba de cortes de luz: dos ranuras A/B que se alternan.
//
// Cada ranura es un archivo de la FAT32 creado una sola vez con capacidad
// fija. Hay dos "juegos" de ranuras independientes: el 0 (CKPT_A.BIN,
// CKPT_B.BIN) para la prueba del hito 14 y el 1 (ENCA_A.BIN, ENCA_B.BIN)
// para el estado de ENCA; cada uno con su capacidad y su cabecera propia; después solo se escriben sus sectores, sin
// tocar la FAT ni el directorio. Formato:
//   sector 0, cabecera: +0 magia "ELECKPT1", +8 versión, +16 paso de
//   entrenamiento, +24 bytes de datos, +32 CRC de los datos,
//   +40 CRC de los 40 bytes anteriores
//   sectores 1..: los datos
// Versión 2 (la que se escribe desde el hito 22): los CRC son CRC32C
// (Castagnoli, instrucción CRC32 de SSE4.2). Versión 1 (hitos 14 a 21): CRC32
// por software; se sigue LEYENDO para no perder estados guardados, pero al
// guardar siempre se escribe la versión 2.
// Orden de escritura: datos, vaciar la caché del disco, cabecera, vaciar.
// Si se corta antes de la cabecera, la ranura conserva la cabecera vieja,
// cuyo CRC ya no coincide con los datos: queda inválida, y al arrancar se
// carga la otra ranura (la del paso anterior), que no se tocó.

take nucleo.mem
take mem.monton
take almacenamiento.disco
take almacenamiento.fat32
take lib.crc32
take lib.consola
take dispositivos.apic
take nucleo.cpu

fixed MAGIA = 0x3154504B43454C45      // "ELECKPT1"
fixed VERSION = 2                     // CRC32C
fixed VERSION_ANTIGUA = 1             // CRC32 (solo lectura)

expose fixed CKPT_PRUEBA = 0
expose fixed CKPT_ENCA = 1

// Estado de cada juego (48 bytes): +0 capacidad de datos, +8 cabecera
// (512 bytes, del montón), +16 ranura de la última carga (0 A, 1 B, -1
// ninguna), +24 paso cargado, +32 ranura de la última escritura, +40 versión
// del formato de la última ranura cargada.
flow estados() => Int { give reservar(96, 8) }
flow estado(juego: Int) => Int { give estados() + juego * 48 }

// Medidas de la última operación (64 bytes), en ciclos de TSC:
// +0 CRC de los datos, +8 E/S de los datos, +16 vaciados de la caché del
// disco, +24 cabeceras (lecturas y escritura), +32 bytes de datos,
// +40 1 si fue guardar y 0 si fue cargar.
flow medidas() => Int { give reservar(64, 8) }

flow medidasReiniciar(guardar: Bool) {
    hold m = medidas()
    each i among 0..8 { escribir64(m + i * 8, 0) }
    when guardar { escribir64(m + 40, 1) }
}

// CRC de los datos según la versión del formato; suma sus ciclos.
flow crcDatos(version: Int, dir: Int, bytes: Int) => Int {
    hold t0 = rdtsc()
    change crc = 0
    when version == VERSION_ANTIGUA { crc = crc32(dir, bytes) } otherwise { crc = crc32cSse(dir, bytes) }
    hold m = medidas()
    escribir64(m, leer64(m) + rdtsc() - t0)
    give crc
}

expose flow ckptVersionCargada(juego: Int) => Int { give leer64(estado(juego) + 40) }

// "N ms (X,Y MB/s)" para `bytes` en `ciclos`.
flow imprimirParte(bytes: Int, ciclos: Int) {
    hold cpm = tscCiclosPorMs()
    kprintEntero(ciclos / cpm)
    kprint(cadena(" ms"))
    when bytes > 0 && ciclos > 0 {
        hold d10 = bytes * cpm * 10 / (ciclos * 1000)
        kprint(cadena(" ("))
        kprintEntero(d10 / 10)
        kprintByte(46)
        kprintEntero(d10 % 10)
        kprint(cadena(" MB/s)"))
    }
}

// Desglose de la última operación de guardar o cargar: `ciclosCopia` es lo
// que gastó quien llama en serializar (guardar) o copiar al modelo (cargar).
expose flow ckptImprimirDesglose(ciclosCopia: Int) {
    hold m = medidas()
    hold bytes = leer64(m + 32)
    hold guardar = leer64(m + 40) == 1
    hold crc = leer64(m)
    hold es = leer64(m + 8)
    hold vaciado = leer64(m + 16)
    hold cabeceras = leer64(m + 24)
    hold total = ciclosCopia + crc + es + vaciado + cabeceras
    kprint(cadena("  desglose "))
    when guardar { kprint(cadena("(guardar), ")) } otherwise { kprint(cadena("(cargar), ")) }
    kprintEntero(bytes)
    kprint(cadena(" B: "))
    when guardar { kprint(cadena("serializar ")) } otherwise { kprint(cadena("copiar al modelo ")) }
    imprimirParte(bytes, ciclosCopia)
    kprint(cadena("; CRC "))
    imprimirParte(bytes, crc)
    kprint(cadena("; E/S de disco "))
    imprimirParte(bytes, es)
    kprint(cadena("; vaciado "))
    imprimirParte(0, vaciado)
    kprint(cadena("; cabeceras "))
    imprimirParte(0, cabeceras)
    kprint(cadena("; total "))
    imprimirParte(bytes, total)
    kprintByte(10)
}

expose flow ckptRanuraGuardada(juego: Int) => Int { give leer64(estado(juego) + 32) }

expose flow ckptRanuraCargada(juego: Int) => Int { give leer64(estado(juego) + 16) }
expose flow ckptPasoCargado(juego: Int) => Int { give leer64(estado(juego) + 24) }

flow abrirRanura(juego: Int, ranura: Int) => Bool {
    when juego == CKPT_ENCA {
        when ranura == 0 { give fatAbrir(cadena("ENCA_A.BIN")) }
        give fatAbrir(cadena("ENCA_B.BIN"))
    }
    when ranura == 0 { give fatAbrir(cadena("CKPT_A.BIN")) }
    give fatAbrir(cadena("CKPT_B.BIN"))
}

// Fija la capacidad del juego (y reserva su búfer de cabecera) sin tocar
// la FAT: basta para cargar ranuras que ya existen.
expose flow ckptConfigurar(juego: Int, capacidad: Int) {
    hold e = estado(juego)
    escribir64(e, (capacidad + 511) / 512 * 512)
    when leer64(e + 8) == 0 { escribir64(e + 8, montonReservar(512)) }
    escribir64(e + 16, -1)
}

// Crea las dos ranuras del juego (si no existen o son pequeñas) para
// `capacidad` bytes de datos. Única operación que toca la FAT.
expose flow ckptPreparar(juego: Int, capacidad: Int) => Bool {
    ckptConfigurar(juego, capacidad)
    hold bytes = leer64(estado(juego)) + 512
    change a = false
    change b = false
    when juego == CKPT_ENCA {
        a = fatCrear(cadena("ENCA_A  BIN"), cadena("ENCA_A.BIN"), bytes)
        b = fatCrear(cadena("ENCA_B  BIN"), cadena("ENCA_B.BIN"), bytes)
    } otherwise {
        a = fatCrear(cadena("CKPT_A  BIN"), cadena("CKPT_A.BIN"), bytes)
        b = fatCrear(cadena("CKPT_B  BIN"), cadena("CKPT_B.BIN"), bytes)
    }
    give a && b && discoVaciar()
}

// Paso guardado en la ranura si su cabecera es válida (sin comprobar los
// datos); -1 si no.
flow pasoDeCabecera(juego: Int, ranura: Int) => Int {
    hold c = leer64(estado(juego) + 8)
    when !abrirRanura(juego, ranura) { give -1 }
    hold t0 = rdtsc()
    hold leidos = fatLeer(0, 512, c)
    hold m = medidas()
    escribir64(m + 24, leer64(m + 24) + rdtsc() - t0)
    when leidos != 512 { give -1 }
    hold version = leer64(c + 8)
    when leer64(c) != MAGIA || (version != VERSION && version != VERSION_ANTIGUA) { give -1 }
    change crc = 0
    when version == VERSION_ANTIGUA { crc = crc32(c, 40) } otherwise { crc = crc32cSse(c, 40) }
    when leer64(c + 40) != crc { give -1 }
    give leer64(c + 16)
}

// Carga la ranura válida más reciente en `dir` (hasta la capacidad).
// Devuelve el paso, o -1 si ninguna ranura es válida.
expose flow ckptCargar(juego: Int, dir: Int) => Int {
    hold e = estado(juego)
    medidasReiniciar(false)
    escribir64(e + 16, -1)
    hold pa = pasoDeCabecera(juego, 0)
    hold pb = pasoDeCabecera(juego, 1)
    // Primero la más reciente; si sus datos no cuadran, la otra.
    change orden0 = 0
    when pb > pa { orden0 = 1 }
    each intento among 0..2 {
        change ranura = orden0
        when intento == 1 { ranura = 1 - orden0 }
        hold paso = pasoDeCabecera(juego, ranura)
        when paso >= 0 {
            // pasoDeCabecera dejó abierta la ranura y su cabecera en `c`.
            hold c = leer64(e + 8)
            hold bytes = leer64(c + 24)
            hold crc = leer64(c + 32)
            when bytes <= leer64(e) {
                hold version = leer64(c + 8)
                hold leidos = leerDatos(bytes, dir)
                when leidos == bytes && crcDatos(version, dir, bytes) == crc {
                    escribir64(e + 16, ranura)
                    escribir64(e + 24, paso)
                    escribir64(e + 40, version)
                    give paso
                }
            }
        }
    }
    give -1
}

// fatLeerDesde512 con su tiempo y sus bytes anotados en las medidas.
flow leerDatos(bytes: Int, dir: Int) => Int {
    hold t0 = rdtsc()
    hold n = fatLeerDesde512(bytes, dir)
    hold m = medidas()
    escribir64(m + 8, leer64(m + 8) + rdtsc() - t0)
    escribir64(m + 32, bytes)
    give n
}

// Lee `bytes` de datos (a partir del sector 1) del archivo abierto.
flow fatLeerDesde512(bytes: Int, dir: Int) => Int {
    hold tam_cluster = fatBytesPorCluster()
    // fatLeer pide desplazamientos múltiplos del cluster: se lee el primer
    // cluster aparte y se copia desde el byte 512.
    hold primero = montonReservar(tam_cluster)
    hold n0 = fatLeer(0, tam_cluster, primero)
    change copiar = tam_cluster - 512
    when copiar > bytes { copiar = bytes }
    each i among 0..copiar { escribir8(dir + i, leer8(primero + 512 + i)) }
    montonLiberar(primero)
    when n0 < 512 + copiar { give 0 }
    when bytes == copiar { give copiar }
    give copiar + fatLeer(tam_cluster, bytes - copiar, dir + copiar)
}

// Guarda `bytes` de `dir` como el paso `paso` en la ranura que NO tiene el
// último checkpoint válido. `cortar` = simular un corte de luz a mitad
// (solo la mitad de los datos, sin cabecera).
expose flow ckptGuardar(juego: Int, paso: Int, dir: Int, bytes: Int, cortar: Bool) => Bool {
    hold e = estado(juego)
    medidasReiniciar(true)
    when bytes > leer64(e) { give false }
    hold pa = pasoDeCabecera(juego, 0)
    hold pb = pasoDeCabecera(juego, 1)
    change ranura = 0
    when pa >= 0 && (pb < 0 || pa > pb) { ranura = 1 }
    give escribirRanura(juego, ranura, paso, dir, bytes, cortar)
}

// Guarda como el paso `paso` en la ranura elegida (0 A, 1 B). Mismo orden de
// escritura que ckptGuardar (datos, vaciar, cabecera, vaciar).
expose flow ckptGuardarEn(juego: Int, ranura: Int, paso: Int, dir: Int, bytes: Int) => Bool {
    medidasReiniciar(true)
    when bytes > leer64(estado(juego)) { give false }
    give escribirRanura(juego, ranura, paso, dir, bytes, false)
}

// Paso de la ranura (cabecera válida, sin comprobar los datos); -1 si no.
expose flow ckptPasoRanura(juego: Int, ranura: Int) => Int { give pasoDeCabecera(juego, ranura) }

// CRC de los datos según la cabecera de la ranura; -1 si la cabecera no es válida.
expose flow ckptCrcRanura(juego: Int, ranura: Int) => Int {
    when pasoDeCabecera(juego, ranura) < 0 { give -1 }
    give leer64(leer64(estado(juego) + 8) + 32)
}

// Carga una ranura concreta en `dir` (sus datos deben cuadrar con el CRC).
// Devuelve su paso, o -1 si la cabecera o los datos no son válidos.
expose flow ckptCargarRanura(juego: Int, ranura: Int, dir: Int) => Int {
    hold e = estado(juego)
    medidasReiniciar(false)
    escribir64(e + 16, -1)
    hold paso = pasoDeCabecera(juego, ranura)
    when paso < 0 { give -1 }
    hold c = leer64(e + 8)
    hold bytes = leer64(c + 24)
    hold crc = leer64(c + 32)
    when bytes > leer64(e) { give -1 }
    hold version = leer64(c + 8)
    hold leidos = leerDatos(bytes, dir)
    when leidos == bytes && crcDatos(version, dir, bytes) == crc {
        escribir64(e + 16, ranura)
        escribir64(e + 24, paso)
        escribir64(e + 40, version)
        give paso
    }
    give -1
}

flow escribirRanura(juego: Int, ranura: Int, paso: Int, dir: Int, bytes: Int, cortar: Bool) => Bool {
    hold e = estado(juego)
    hold m = medidas()
    hold sectores = (bytes + 511) / 512
    when !abrirRanura(juego, ranura) { give false }
    escribir64(e + 32, ranura)
    escribir64(m + 32, bytes)
    // El CRC32C de los datos se calcula antes de tocar el disco (a varios
    // GB/s: unos pocos % del tiempo de E/S).
    hold crc = crcDatos(VERSION, dir, bytes)
    change escribir = sectores
    when cortar { escribir = sectores / 2 }
    // Los datos van en el búfer de llamada; el último sector incompleto se
    // escribe completo (lo que sobre después de `bytes` no cuenta en el CRC).
    hold t0 = rdtsc()
    when !fatEscribir(512, escribir * 512, dir) { give false }
    hold t1 = rdtsc()
    escribir64(m + 8, leer64(m + 8) + t1 - t0)
    when !discoVaciar() { give false }
    hold t2 = rdtsc()
    escribir64(m + 16, leer64(m + 16) + t2 - t1)
    when cortar { give true }
    hold c = leer64(e + 8)
    each i among 0..64 { escribir64(c + i * 8, 0) }
    escribir64(c, MAGIA)
    escribir64(c + 8, VERSION)
    escribir64(c + 16, paso)
    escribir64(c + 24, bytes)
    escribir64(c + 32, crc)
    escribir64(c + 40, crc32cSse(c, 40))
    hold t3 = rdtsc()
    when !fatEscribir(0, 512, c) { give false }
    hold t4 = rdtsc()
    escribir64(m + 24, leer64(m + 24) + t4 - t3)
    hold bien = discoVaciar()
    escribir64(m + 16, leer64(m + 16) + rdtsc() - t4)
    give bien
}
