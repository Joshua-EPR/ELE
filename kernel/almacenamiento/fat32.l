// FAT32 sobre la partición permitida (almacenamiento/disco.l).
//
// Lectura: archivos por ruta ("texto.txt", "datos/corpus.txt"), con nombres
// largos (VFAT, comparación sin distinguir mayúsculas en ASCII) o 8.3.
// Escritura simple: crear o sobrescribir un archivo del directorio raíz con
// nombre 8.3. Todo pasa por discoEscribir, que solo permite escribir dentro
// de la partición marcada.
//
// Un "archivo abierto" es el último encontrado o creado: primer cluster,
// tamaño y la posición de su entrada de directorio (LBA y desplazamiento).

take nucleo.mem
take mem.monton
take almacenamiento.disco
take lib.consola

// Estado: +0 montado, +8 LBA de la partición, +16 sectores por cluster,
// +24 primer sector de la FAT, +32 sectores por FAT, +40 número de FAT,
// +48 primer sector de datos, +56 cluster raíz, +64 clusters totales,
// +72 búfer de sector (FAT), +80 sector en el búfer (-1 ninguno),
// +88 búfer de cluster, +96 archivo: primer cluster, +104 tamaño,
// +112 LBA de su entrada, +120 desplazamiento de su entrada,
// +128 búfer del nombre largo (256 bytes), +136 pista de cluster libre,
// +144 sector FSInfo (relativo a la partición), +152 FSInfo ya invalidado,
// +160 el sector de FAT en el búfer tiene cambios sin escribir (1/0),
// +168 modo diferido: fatPoner no escribe hasta cambiar de sector o vaciar.
flow estado() => Int { give reservar(176, 8) }

expose flow fatTamanoArchivo() => Int { give leer64(estado() + 104) }
expose flow fatBytesPorCluster() => Int { give leer64(estado() + 16) * 512 }

flow lbaDeCluster(c: Int) => Int {
    hold e = estado()
    give leer64(e + 8) + leer64(e + 48) + (c - 2) * leer64(e + 16)
}

// ---- FAT ---------------------------------------------------------------------

// Escribe en todas las copias de la FAT el sector que está en el búfer.
flow vaciarSectorFat() => Bool {
    hold e = estado()
    when leer64(e + 160) == 0 { give true }
    escribir64(e + 160, 0)
    each f among 0..leer64(e + 40) {
        when !discoEscribir(leer64(e + 8) + leer64(e + 24) + f * leer64(e + 32) + leer64(e + 80), 1, leer64(e + 72)) { give false }
    }
    give true
}

flow sectorFat(s: Int) => Int {
    hold e = estado()
    hold buf = leer64(e + 72)
    when leer64(e + 80) != s {
        when !vaciarSectorFat() { give 0 }
        when !discoLeer(leer64(e + 8) + leer64(e + 24) + s, 1, buf) { give 0 }
        escribir64(e + 80, s)
    }
    give buf
}

expose flow fatSiguiente(c: Int) => Int {
    hold buf = sectorFat(c * 4 / 512)
    when buf == 0 { give 0x0FFFFFFF }
    give leer32(buf + (c * 4) % 512) & 0x0FFFFFFF
}

// Escribe la entrada `c` = `valor` en TODAS las copias de la FAT.
flow fatPoner(c: Int, valor: Int) => Bool {
    hold e = estado()
    hold s = c * 4 / 512
    hold buf = sectorFat(s)
    when buf == 0 { give false }
    hold desp = (c * 4) % 512
    escribir32(buf + desp, (leer32(buf + desp) & 0xF0000000) | (valor & 0x0FFFFFFF))
    escribir64(e + 160, 1)
    when leer64(e + 168) == 1 { give true }
    give vaciarSectorFat()
}

flow esFin(c: Int) => Bool { give c < 2 || c >= 0x0FFFFFF8 }

// ---- montaje -----------------------------------------------------------------

// Monta la FAT32 de la partición permitida. false si no es FAT32.
expose flow fatMontar() => Bool {
    hold e = estado()
    escribir64(e, 0)
    when !discoHayPermitida() { give false }
    hold lba = discoPermitidoPrimero()
    when leer64(e + 72) == 0 {
        escribir64(e + 72, montonReservar(512))
        escribir64(e + 128, montonReservar(256))
    }
    hold s = montonReservar(512)
    change bien = discoLeer(lba, 1, s)
    bien = bien && leer16(s + 11) == 512 && leer16(s + 22) == 0 && leer16(s + 510) == 0xAA55
    when bien {
        escribir64(e + 8, lba)
        escribir64(e + 16, leer8(s + 13))
        escribir64(e + 24, leer16(s + 14))
        escribir64(e + 40, leer8(s + 16))
        escribir64(e + 32, leer32(s + 36))
        escribir64(e + 48, leer16(s + 14) + leer8(s + 16) * leer32(s + 36))
        escribir64(e + 56, leer32(s + 44))
        escribir64(e + 64, (leer32(s + 32) - leer64(e + 48)) / leer8(s + 13))
        escribir64(e + 80, -1)
        escribir64(e + 160, 0)
        escribir64(e + 168, 0)
        escribir64(e + 136, 2)
        escribir64(e + 144, leer16(s + 48))
        escribir64(e + 152, 0)
        when leer64(e + 88) != 0 { montonLiberar(leer64(e + 88)) }
        escribir64(e + 88, montonReservar(leer8(s + 13) * 512))
        escribir64(e, 1)
    }
    montonLiberar(s)
    give bien
}

// ---- directorios -------------------------------------------------------------

flow minuscula(c: Int) => Int {
    when c >= 65 && c <= 90 { give c + 32 }
    give c
}

// Compara el componente `nombre` (bytes `desde`..`hasta` de un registro de
// cadena) con el nombre largo acumulado (`largo`, terminado en 0) o con el
// nombre corto de la entrada.
flow coincide(texto: Int, desde: Int, hasta: Int, largo: Int, entrada: Int) => Bool {
    hold n = hasta - desde
    when leer8(largo) != 0 {
        each i among 0..n {
            when minuscula(leer8(largo + i)) != minuscula(leer8(texto + 8 + desde + i)) { give false }
        }
        give leer8(largo + n) == 0
    }
    // 8.3: "NOMBRE.EXT" sin los espacios de relleno.
    change k = 0
    each i among 0..11 {
        hold c = leer8(entrada + i)
        when i == 8 && leer8(entrada + 8) != 32 {
            when k >= n || leer8(texto + 8 + desde + k) != 46 { give false }
            k += 1
        }
        when c != 32 {
            when k >= n || minuscula(c) != minuscula(leer8(texto + 8 + desde + k)) { give false }
            k += 1
        }
    }
    give k == n
}

// Acumula los caracteres (ASCII/Latin-1) de una entrada LFN en `largo`.
flow acumularLfn(entrada: Int, largo: Int) {
    hold orden = leer8(entrada) & 0x1F
    hold base = (orden - 1) * 13
    each i among 0..13 {
        change desp = 1 + i * 2
        when i >= 5 { desp = 14 + (i - 5) * 2 }
        when i >= 11 { desp = 28 + (i - 11) * 2 }
        hold u = leer16(entrada + desp)
        when base + i < 255 {
            change c = u
            when u == 0xFFFF { c = 0 }
            when u > 0xFF { c = 63 }
            escribir8(largo + base + i, c)
        }
    }
    when leer8(entrada) & 0x40 != 0 && base + 13 < 256 { escribir8(largo + base + 13, 0) }
}

// Busca el componente en el directorio que empieza en `cluster`. Si lo
// encuentra deja el archivo abierto y devuelve true.
flow buscarEn(cluster: Int, texto: Int, desde: Int, hasta: Int) => Bool {
    hold e = estado()
    hold buf = leer64(e + 88)
    hold largo = leer64(e + 128)
    hold bytes = fatBytesPorCluster()
    escribir8(largo, 0)
    change c = cluster
    during !esFin(c) {
        when !discoLeer(lbaDeCluster(c), leer64(e + 16), buf) { give false }
        change p = 0
        during p < bytes {
            hold ent = buf + p
            hold primero = leer8(ent)
            when primero == 0 { give false }
            when primero != 0xE5 {
                when leer8(ent + 11) == 0x0F {
                    acumularLfn(ent, largo)
                } otherwise {
                    when leer8(ent + 11) & 0x08 == 0 && coincide(texto, desde, hasta, largo, ent) {
                        escribir64(e + 96, (leer16(ent + 20) << 16) | leer16(ent + 26))
                        escribir64(e + 104, leer32(ent + 28))
                        escribir64(e + 112, lbaDeCluster(c) + p / 512)
                        escribir64(e + 120, p % 512)
                        give true
                    }
                    escribir8(largo, 0)
                }
            }
            p += 32
        }
        c = fatSiguiente(c)
    }
    give false
}

// Abre la ruta (registro de cadena, separada por '/'). true si existe.
expose flow fatAbrir(ruta: Int) => Bool {
    hold e = estado()
    when leer64(e) != 1 { give false }
    hold n = leer64(ruta)
    change cluster = leer64(e + 56)
    change desde = 0
    during desde < n {
        change hasta = desde
        during hasta < n && leer8(ruta + 8 + hasta) != 47 { hasta += 1 }
        when !buscarEn(cluster, ruta, desde, hasta) { give false }
        cluster = leer64(e + 96)
        desde = hasta + 1
    }
    give true
}

// Lee `bytes` del archivo abierto desde `desplazamiento` (múltiplo del
// tamaño de cluster) a `dir`. Devuelve los bytes leídos.
expose flow fatLeer(desplazamiento: Int, bytes: Int, dir: Int) => Int {
    hold e = estado()
    hold tam_cluster = fatBytesPorCluster()
    hold spc = leer64(e + 16)
    change total = bytes
    when desplazamiento + total > leer64(e + 104) { total = leer64(e + 104) - desplazamiento }
    when total <= 0 { give 0 }
    change c = leer64(e + 96)
    change saltar = desplazamiento / tam_cluster
    during saltar > 0 && !esFin(c) {
        c = fatSiguiente(c)
        saltar -= 1
    }
    hold buf = leer64(e + 88)
    change hecho = 0
    during hecho < total && !esFin(c) {
        change resto = total - hecho
        when resto >= tam_cluster {
            // Clusters contiguos en una sola lectura.
            change seguidos = 1
            during seguidos * tam_cluster <= resto - tam_cluster && fatSiguiente(c + seguidos - 1) == c + seguidos {
                seguidos += 1
            }
            when !discoLeer(lbaDeCluster(c), seguidos * spc, dir + hecho) { give hecho }
            hecho += seguidos * tam_cluster
            each s among 0..seguidos { c = fatSiguiente(c) }
        } otherwise {
            when !discoLeer(lbaDeCluster(c), spc, buf) { give hecho }
            each i among 0..resto { escribir8(dir + hecho + i, leer8(buf + i)) }
            hecho += resto
            c = fatSiguiente(c)
        }
    }
    give hecho
}

// ---- escritura -------------------------------------------------------------

flow clusterLibre() => Int {
    hold e = estado()
    hold total = leer64(e + 64) + 2
    change c = leer64(e + 136)
    change vueltas = 0
    during vueltas < total {
        when c >= total { c = 2 }
        when fatSiguiente(c) == 0 {
            escribir64(e + 136, c + 1)
            give c
        }
        c += 1
        vueltas += 1
    }
    give 0
}

flow liberarCadena(primero: Int) => Bool {
    hold e = estado()
    escribir64(e + 168, 1)
    change c = primero
    change bien = true
    during !esFin(c) && bien {
        hold siguiente = fatSiguiente(c)
        bien = fatPoner(c, 0)
        c = siguiente
    }
    escribir64(e + 168, 0)
    give bien && vaciarSectorFat()
}

// FSInfo guarda una pista de clusters libres; al reservar deja de ser
// exacta, así que se marca como desconocida (0xFFFFFFFF, válido en FAT32)
// una vez por montaje.
flow invalidarFsInfo() => Bool {
    hold e = estado()
    when leer64(e + 152) == 1 || leer64(e + 144) == 0 { give true }
    hold s = montonReservar(512)
    hold lba = leer64(e + 8) + leer64(e + 144)
    change bien = discoLeer(lba, 1, s)
    when bien && leer32(s) == 0x41615252 && leer32(s + 484) == 0x61417272 {
        escribir32(s + 488, 0xFFFFFFFF)
        escribir32(s + 492, 0xFFFFFFFF)
        bien = discoEscribir(lba, 1, s)
    }
    montonLiberar(s)
    escribir64(e + 152, 1)
    give bien
}

// Reserva una cadena de clusters para `bytes`. Devuelve el primero o 0.
flow reservarCadena(bytes: Int) => Int {
    when !invalidarFsInfo() { give 0 }
    hold cuantos = (bytes + fatBytesPorCluster() - 1) / fatBytesPorCluster()
    hold e = estado()
    // Diferido: cada sector de la FAT se escribe una vez, no una por cluster.
    escribir64(e + 168, 1)
    change primero = 0
    change anterior = 0
    change bien = true
    each i among 0..cuantos {
        when bien {
            hold c = clusterLibre()
            when c == 0 { bien = false }
            when bien && !fatPoner(c, 0x0FFFFFFF) { bien = false }
            when bien {
                when anterior != 0 {
                    when !fatPoner(anterior, c) { bien = false }
                } otherwise {
                    primero = c
                }
                anterior = c
            }
        }
    }
    escribir64(e + 168, 0)
    when !vaciarSectorFat() { bien = false }
    when !bien { give 0 }
    give primero
}

flow escribirEntrada(lba: Int, desp: Int, nombre83: Int, primero: Int, tamano: Int) => Bool {
    hold s = montonReservar(512)
    change bien = discoLeer(lba, 1, s)
    when bien {
        hold ent = s + desp
        each i among 0..11 { escribir8(ent + i, leer8(nombre83 + 8 + i)) }
        escribir8(ent + 11, 0x20)
        each i among 12..32 { escribir8(ent + i, 0) }
        escribir16(ent + 20, primero >> 16)
        escribir16(ent + 26, primero & 0xFFFF)
        escribir32(ent + 28, tamano)
        bien = discoEscribir(lba, 1, s)
    }
    montonLiberar(s)
    give bien
}

// Busca una entrada libre en el directorio raíz (no lo amplía).
flow entradaLibre() => Bool {
    hold e = estado()
    hold buf = leer64(e + 88)
    hold bytes = fatBytesPorCluster()
    change c = leer64(e + 56)
    during !esFin(c) {
        when !discoLeer(lbaDeCluster(c), leer64(e + 16), buf) { give false }
        change p = 0
        during p < bytes {
            hold primero = leer8(buf + p)
            when primero == 0 || primero == 0xE5 {
                escribir64(e + 112, lbaDeCluster(c) + p / 512)
                escribir64(e + 120, p % 512)
                give true
            }
            p += 32
        }
        c = fatSiguiente(c)
    }
    give false
}

// Crea (o sobrescribe) en la raíz el archivo de nombre 8.3 `nombre83`
// (registro de cadena con los 11 caracteres "NOMBRE  EXT"), con espacio
// para `bytes`. Si ya existe con espacio suficiente se reutilizan sus
// clusters (sin tocar la FAT). Lo deja abierto.
expose flow fatCrear(nombre83: Int, nombre: Int, bytes: Int) => Bool {
    hold e = estado()
    when leer64(e) != 1 { give false }
    when fatAbrir(nombre) {
        hold primero = leer64(e + 96)
        change capacidad = 0
        change c = primero
        during !esFin(c) {
            capacidad += fatBytesPorCluster()
            c = fatSiguiente(c)
        }
        when capacidad >= bytes && primero >= 2 {
            escribir64(e + 104, bytes)
            give escribirEntrada(leer64(e + 112), leer64(e + 120), nombre83, primero, bytes)
        }
        when primero >= 2 && !liberarCadena(primero) { give false }
    } otherwise {
        when !entradaLibre() { give false }
    }
    hold primero = reservarCadena(bytes)
    when primero == 0 { give false }
    escribir64(e + 96, primero)
    escribir64(e + 104, bytes)
    give escribirEntrada(leer64(e + 112), leer64(e + 120), nombre83, primero, bytes)
}

// Escribe `bytes` (múltiplo de 512) en el archivo abierto desde
// `desplazamiento` (múltiplo de 512), dentro de los clusters ya reservados.
// Los clusters contiguos se escriben con una sola orden de disco.
expose flow fatEscribir(desplazamiento: Int, bytes: Int, dir: Int) => Bool {
    hold e = estado()
    hold tam_cluster = fatBytesPorCluster()
    hold spc = leer64(e + 16)
    change c = leer64(e + 96)
    change saltar = desplazamiento / tam_cluster
    during saltar > 0 && !esFin(c) {
        c = fatSiguiente(c)
        saltar -= 1
    }
    change dentro = (desplazamiento % tam_cluster) / 512
    change hecho = 0
    during hecho < bytes {
        when esFin(c) { give false }
        change sectores = spc - dentro
        when sectores * 512 > bytes - hecho { sectores = (bytes - hecho) / 512 }
        // Extiende el tramo mientras el siguiente cluster sea el contiguo.
        change ultimo = c
        change siguiente = fatSiguiente(c)
        during siguiente == ultimo + 1 && (sectores + spc) * 512 <= bytes - hecho {
            sectores += spc
            ultimo = siguiente
            siguiente = fatSiguiente(ultimo)
        }
        when !discoEscribir(lbaDeCluster(c) + dentro, sectores, dir + hecho) { give false }
        hecho += sectores * 512
        dentro = 0
        c = siguiente
    }
    give true
}
