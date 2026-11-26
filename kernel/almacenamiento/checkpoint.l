// Checkpoints a prueba de cortes de luz: dos ranuras A/B que se alternan.
//
// Cada ranura es un archivo de la FAT32 creado una sola vez con capacidad
// fija. Hay dos "juegos" de ranuras independientes: el 0 (CKPT_A.BIN,
// CKPT_B.BIN) para la prueba del hito 14 y el 1 (ENCA_A.BIN, ENCA_B.BIN)
// para el estado de ENCA; cada uno con su capacidad y su cabecera propia; después solo se escriben sus sectores, sin
// tocar la FAT ni el directorio. Formato:
//   sector 0, cabecera: +0 magia "ELECKPT1", +8 versión, +16 paso de
//   entrenamiento, +24 bytes de datos, +32 CRC32 de los datos,
//   +40 CRC32 de los 40 bytes anteriores
//   sectores 1..: los datos
// Orden de escritura: datos, vaciar la caché del disco, cabecera, vaciar.
// Si se corta antes de la cabecera, la ranura conserva la cabecera vieja,
// cuyo CRC ya no coincide con los datos: queda inválida, y al arrancar se
// carga la otra ranura (la del paso anterior), que no se tocó.

take nucleo.mem
take mem.monton
take almacenamiento.disco
take almacenamiento.fat32
take lib.crc32

fixed MAGIA = 0x3154504B43454C45      // "ELECKPT1"
fixed VERSION = 1

expose fixed CKPT_PRUEBA = 0
expose fixed CKPT_ENCA = 1

// Estado de cada juego (48 bytes): +0 capacidad de datos, +8 cabecera
// (512 bytes, del montón), +16 ranura de la última carga (0 A, 1 B, -1
// ninguna), +24 paso cargado, +32 ranura de la última escritura.
flow estados() => Int { give reservar(96, 8) }
flow estado(juego: Int) => Int { give estados() + juego * 48 }

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
    when fatLeer(0, 512, c) != 512 { give -1 }
    when leer64(c) != MAGIA || leer64(c + 8) != VERSION { give -1 }
    when leer64(c + 40) != crc32(c, 40) { give -1 }
    give leer64(c + 16)
}

// Carga la ranura válida más reciente en `dir` (hasta la capacidad).
// Devuelve el paso, o -1 si ninguna ranura es válida.
expose flow ckptCargar(juego: Int, dir: Int) => Int {
    hold e = estado(juego)
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
                hold leidos = fatLeerDesde512(bytes, dir)
                when leidos == bytes && crc32(dir, bytes) == crc {
                    escribir64(e + 16, ranura)
                    escribir64(e + 24, paso)
                    give paso
                }
            }
        }
    }
    give -1
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
    when bytes > leer64(e) { give false }
    hold pa = pasoDeCabecera(juego, 0)
    hold pb = pasoDeCabecera(juego, 1)
    change ranura = 0
    when pa >= 0 && (pb < 0 || pa > pb) { ranura = 1 }
    hold sectores = (bytes + 511) / 512
    when !abrirRanura(juego, ranura) { give false }
    escribir64(e + 32, ranura)
    change escribir = sectores
    when cortar { escribir = sectores / 2 }
    // Los datos van en el búfer de llamada; el último sector incompleto se
    // escribe completo (lo que sobre después de `bytes` no cuenta en el CRC).
    when !fatEscribir(512, escribir * 512, dir) { give false }
    when !discoVaciar() { give false }
    when cortar { give true }
    hold c = leer64(e + 8)
    each i among 0..64 { escribir64(c + i * 8, 0) }
    escribir64(c, MAGIA)
    escribir64(c + 8, VERSION)
    escribir64(c + 16, paso)
    escribir64(c + 24, bytes)
    escribir64(c + 32, crc32(dir, bytes))
    escribir64(c + 40, crc32(c, 40))
    when !fatEscribir(0, 512, c) { give false }
    give discoVaciar()
}
