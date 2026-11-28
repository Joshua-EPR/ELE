// ENCA: entrenamiento largo, reanudable y a prueba de apagones (hito 24 de la
// Fase 4; opción de arranque enca=entrenar).
//
// Qué hace: entrena el modelo hablante (C5, modo rápido; ranuras por orden
// configurables) por pasadas sobre f4/entrena.bin, documento a documento
// (vigilia + 2 sueños, igual que enca=hablar), sin cargar el corpus entero en
// RAM (cada documento se lee con fatLeer en un búfer del tamaño del mayor). Cada
// ent_min minutos del reloj del kernel (y tras cada punto de evaluación) guarda
// un checkpoint en ENTREN_A.BIN / ENTREN_B.BIN (checkpoint.l, juego
// CKPT_ENTRENA, formato 2 con CRC32C), SIEMPRE en una frontera de documento.
// Al arrancar con ENTREN_* válidas y compatibles reanuda desde ellas; el
// resultado es bit a bit el de un entrenamiento sin cortes.
//
// Opciones de arranque (claves "clave=valor" separadas por espacios; todas
// opcionales salvo enca=entrenar):
//   enca=entrenar     activa este modo
//   ent_ranuras=N     ranuras por orden del hipocampo (524288); potencia de 2
//   ent_min=N         minutos entre checkpoints (30)
//   ent_mb=N          MB (1 000 000 B) de corpus entre puntos de evaluación (10; 0 = ninguno)
//   ent_pasadas=N     número de pasadas (1)
//   ent_limite=N      límite de MB por pasada (0 = el corpus entero); para pruebas
//   ent_nuevo=1       ignora (y sobrescribe) un entrenamiento guardado
//   ent_retardo=N     solo pruebas: pausa de N ms a mitad de la escritura de cada checkpoint
//
// Archivos en la FAT32 (partición ELEDATOS):
//   f4/entrena.bin .idx .tipos, f4/valida.bin .idx .tipos, f4/prompts.txt  (entrada)
//   ENTREN_A.BIN, ENTREN_B.BIN   checkpoints (cursor + curva + estado de ENCA)
//   M0001.TXT, M0002.TXT, ...    un archivo por punto de evaluación (raíz, 8.3)
//   CURVA.LOG                    una línea por punto (con velocidad y hora del kernel)
//
// Formato de los datos de un checkpoint (palabras de 8 bytes, little-endian):
//   bloque del cursor, CAB_BYTES (262144) bytes:
//     0 magia "ELEENT01"  1 versión  2 ranuras por orden  3 CRC32C de entrena.bin
//     4 CRC32C de valida.bin  5 documentos y 6 bytes de entrena  7 documentos y
//     8 bytes de valida  9 CRC32C de prompts.txt  10 MB entre puntos (en bytes)
//     11 límite por pasada (bytes)  12 banderas (1 = terminado)  13 pasadas pedidas
//     14 pasada actual (desde 1)  15 posición en la permutación (documentos hechos)
//     16 bytes de la pasada  17 bytes totales  18 bits acumulados de la pasada (f64,
//     media precuencial = bits del byte real antes de aprender)  19 semilla PCG de la
//     pasada  20 estado del PCG tras barajar  21 próximo punto de evaluación (bytes
//     totales)  22 puntos de la curva  23 bytes del estado de ENCA
//     32.. la curva: por punto 8 palabras (bytes totales, pasada, bits/byte acumulados,
//     bits/byte de valida, de TEXTO, de DIALOGO, bytes TEXTO, bytes DIALOGO)
//   estado de ENCA (enca/estado.l, encaTamEstado() bytes) desde CAB_BYTES.
//   Nada depende del reloj ni de cuántos checkpoints hubo, así que el CRC32C de los
//   datos es idéntico en un entrenamiento cortado y reanudado y en uno sin cortes.
//
// Puntos de evaluación: por bytes procesados, no por tiempo. En la primera frontera
// de documento con bytes totales >= próximo punto: valida.bin entera congelada
// (bits/byte de la mezcla; total, TEXTO y DIALOGO), las 20 generaciones de
// prompts.txt (protocolo de kernel/herramientas/corpus/evaluacion.md: semilla 4242,
// T 0,5, top-k 0, top-p 1, hasta 300 bytes; los diálogos se detienen en el primer
// salto de línea), el archivo Mnnnn.TXT, la línea de CURVA.LOG y un checkpoint. La
// evaluación no aprende: el estado serializado antes y después tiene el mismo CRC32C
// (se comprueba y se imprime en cada punto).

take nucleo.cpu
take nucleo.mem
take mem.fisica
take mem.monton
take lib.consola
take lib.matf64
take lib.crc32
take lib.aleatorio
take dispositivos.apic
take almacenamiento.disco
take almacenamiento.fat32
take almacenamiento.checkpoint
take arranque.limine
take enca.matematica
take enca.modelo
take enca.perfil
take enca.rapido
take enca.estado
take enca.exp009
take enca.muestreo
take enca.espanol

fixed RANURAS_DEF = 524288
fixed MARGEN = 134217728            // 128 MiB que se dejan libres
fixed SOBRECOSTE = 4194304
fixed CAB_BYTES = 262144
fixed CURVA_PALABRA = 32            // la curva empieza en la palabra 32
fixed MAX_PUNTOS = 4092
fixed MAGIA_ENT = 0x3130544E45454C45  // "ELEENT01"
fixed VERSION_ENT = 1
fixed SEMILLA_PERM = 20261127
fixed SEMILLA_GEN = 4242
fixed MAX_GEN = 300
fixed TROZO_CRC = 8388608
fixed SIN_PUNTOS = 0x3FFFFFFFFFFFFFFF
fixed CAP_TEXTO = 65536
fixed CAP_LOG = 1048576
fixed MAX_PROMPTS = 64

// Palabras del bloque del cursor (en el búfer del checkpoint).
fixed W_MAGIA = 0
fixed W_VERSION = 1
fixed W_RANURAS = 2
fixed W_CRCE = 3
fixed W_CRCV = 4
fixed W_NE = 5
fixed W_BE = 6
fixed W_NV = 7
fixed W_BV = 8
fixed W_CRCP = 9
fixed W_EVAL = 10
fixed W_LIMITE = 11
fixed W_FLAGS = 12
fixed W_PASADAS = 13
fixed W_PASADA = 14
fixed W_K = 15
fixed W_BPASADA = 16
fixed W_BTOT = 17
fixed W_ACC = 18
fixed W_SEMILLA = 19
fixed W_PCG = 20
fixed W_PROXIMO = 21
fixed W_NPUNTOS = 22
fixed W_BESTADO = 23

// Palabras de la configuración y los punteros de la sesión (no se guardan).
fixed K_RANURAS = 0
fixed K_MINUTOS = 1
fixed K_EVAL = 2
fixed K_PASADAS = 3
fixed K_LIMITE = 4
fixed K_NUEVO = 5
fixed K_NE = 6
fixed K_BE = 7
fixed K_NV = 8
fixed K_BV = 9
fixed K_CRCE = 10
fixed K_CRCV = 11
fixed K_CRCP = 12
fixed K_MAXDOC = 13
fixed K_TABE = 14
fixed K_TABV = 15
fixed K_VALIDA = 16
fixed K_TIPOS = 17
fixed K_PROMPTS = 18
fixed K_NPROMPTS = 19
fixed K_DOCBUF = 20
fixed K_PERM = 21
fixed K_BUF = 22
fixed K_TOTAL = 23
fixed K_MODELO = 24
fixed K_LOGBUF = 25
fixed K_LOGLEN = 26
fixed K_TEXTO = 27
fixed K_PROXCKPT = 28
fixed K_PROXLINEA = 29
fixed K_T0 = 30
fixed K_FUERA = 31
fixed K_B0 = 32
fixed K_TABPROMPTS = 33
fixed K_NCKPT = 34
fixed K_PREF = 35
fixed K_TIPOSE = 36
fixed K_DOCCAP = 37

// ---- acceso a la configuración y al bloque del cursor -----------------------------

flow cfg() => Int { give reservar(384, 8) }
flow cfgGet(i: Int) => Int { give leer64(cfg() + i * 8) }
flow cfgSet(i: Int, v: Int) { escribir64(cfg() + i * 8, v) }
flow cabGet(i: Int) => Int { give leer64(cfgGet(K_BUF) + i * 8) }
flow cabSet(i: Int, v: Int) { escribir64(cfgGet(K_BUF) + i * 8, v) }
flow cabGetF(i: Int) => Float { give lf(cfgGet(K_BUF) + i * 8) }
flow cabSetF(i: Int, v: Float) { ef(cfgGet(K_BUF) + i * 8, v) }
// Registro de la curva i, palabra j.
flow recDir(i: Int, j: Int) => Int { give cfgGet(K_BUF) + (CURVA_PALABRA + i * 8 + j) * 8 }

flow ahoraMs() => Int { give rdtsc() / tscCiclosPorMs() }

// ---- opciones -----------------------------------------------------------------------

flow opcionEntero(clave: Int, defecto: Int) => Int {
    hold v = arranqueOpcion(clave)
    when v == 0 { give defecto }
    hold n = leer64(v)
    when n == 0 || n > 15 { give defecto }
    change r = 0
    each i among 0..n {
        hold c = leer8(v + 8 + i)
        when c < 48 || c > 57 { give defecto }
        r = r * 10 + (c - 48)
    }
    give r
}

// ---- texto en memoria ---------------------------------------------------------------

flow pCad(dst: Int, pos: Int, c: Int) => Int {
    hold n = leer64(c)
    each i among 0..n { escribir8(dst + pos + i, leer8(c + 8 + i)) }
    give pos + n
}

flow pBytes(dst: Int, pos: Int, src: Int, n: Int) => Int {
    each i among 0..n { escribir8(dst + pos + i, leer8(src + i)) }
    give pos + n
}

flow pInt(dst: Int, pos: Int, v: Int) => Int { give pos + fmtEntero(v, dst + pos) }
flow pDec(dst: Int, pos: Int, x: Float, dec: Int) => Int { give pos + fmtDecimal(x, dec, dst + pos) }
flow pByte(dst: Int, pos: Int, b: Int) => Int {
    escribir8(dst + pos, b)
    give pos + 1
}

flow pHex8(dst: Int, pos: Int, v: Int) => Int {
    each i among 0..8 {
        hold d = (v >> (28 - 4 * i)) & 0xF
        when d < 10 { escribir8(dst + pos + i, 48 + d) } otherwise { escribir8(dst + pos + i, 55 + d) }
    }
    give pos + 8
}

// Bits por byte (bits / bytes), 0 si no hay bytes.
flow razon(bits: Float, bytes: Int) => Float {
    when bytes <= 0 { give 0.0 }
    give bits / Float(bytes)
}

// ---- tiempos en pantalla ------------------------------------------------------------------

flow imprimirTiempo(segundos: Int) {
    hold h = segundos / 3600
    hold mi = (segundos / 60) % 60
    hold s = segundos % 60
    when h > 0 {
        kprintEntero(h)
        kprint(cadena(" h "))
    }
    kprintEntero(mi)
    kprint(cadena(" min "))
    kprintEntero(s)
    kprint(cadena(" s"))
}

// Décimas: 123 -> "12,3".
flow imprimirDecimas(d: Int) {
    kprintEntero(d / 10)
    kprintByte(44)
    kprintEntero(d % 10)
}

// ---- memoria -------------------------------------------------------------------------------

flow mib(bytes: Int) => Int { give bytes / 1048576 }
flow disponible() => Int { give memFisicaLibres() * MARCO + montonMapeado() - montonEnUso() }
flow bytesModelo(s: Int) => Int { give 5 * s * (24 + 12 * 16) + SOBRECOSTE }

// ---- archivos ---------------------------------------------------------------------------------

// Archivo entero al montón; 0 si no existe, no mide `tam` (si tam >= 0) o no se leyó.
flow leerTodo(ruta: Int, tam: Int) => Int {
    when !fatAbrir(ruta) { give 0 }
    hold t = fatTamanoArchivo()
    when tam >= 0 && t != tam { give 0 }
    hold b = montonReservar(t + 576)
    when b == 0 { give 0 }
    when fatLeer(0, t, b) != t {
        montonLiberar(b)
        give 0
    }
    give b
}

// CRC32C de un archivo grande leído por tramos de 8 MiB; -1 si falla.
flow crcGrande(ruta: Int, tam: Int) => Int {
    hold b = montonReservar(TROZO_CRC + 64)
    when b == 0 { give -1 }
    when !fatAbrir(ruta) || fatTamanoArchivo() != tam {
        montonLiberar(b)
        give -1
    }
    change crc = 0
    change off = 0
    during off < tam {
        change n = tam - off
        when n > TROZO_CRC { n = TROZO_CRC }
        when fatLeer(off, n, b) != n {
            montonLiberar(b)
            give -1
        }
        crc = crc32cContinuarSse(crc, b, n)
        off += n
    }
    montonLiberar(b)
    give crc
}

// Escribe `n` bytes de `datos` (con sitio para el relleno a 512) como archivo de
// la raíz; el tamaño del archivo es exacto (n).
flow escribirRaiz(n83: Int, nombre: Int, datos: Int, n: Int) => Bool {
    when n <= 0 { give false }
    hold pad = (n + 511) / 512 * 512
    each i among n..pad { escribir8(datos + i, 0) }
    when !fatCrear(n83, nombre, n) { give false }
    when !fatEscribir(0, pad, datos) { give false }
    give discoVaciar()
}

// ---- corpus f4/ -----------------------------------------------------------------------------------

// Verifica un índice ELEIDX01 (cabecera, tabla, documentos dentro del .bin) y su .tipos;
// devuelve true si es correcto. `nombre` es solo para los mensajes.
flow verificarIndice(idx: Int, tam: Int, tipos: Int, nombre: Int) => Bool {
    when tam < 128 {
        kprint(nombre)
        kprintln(cadena(": índice demasiado corto"))
        give false
    }
    when leer64(idx) != 0x3130584449454C45 || leer64(idx + 8) != 1 {
        kprint(nombre)
        kprintln(cadena(": magia o versión del índice"))
        give false
    }
    when crc32cSse(idx, 72) != leer64(idx + 72) {
        kprint(nombre)
        kprintln(cadena(": CRC32C de la cabecera del índice"))
        give false
    }
    hold n = leer64(idx + 16)
    hold b = leer64(idx + 32)
    when n < 1 || tam != 128 + n * 16 {
        kprint(nombre)
        kprintln(cadena(": tamaño del índice"))
        give false
    }
    when crc32cSse(idx + 128, n * 16) != leer64(idx + 64) {
        kprint(nombre)
        kprintln(cadena(": CRC32C de la tabla de documentos"))
        give false
    }
    when crc32cSse(tipos, n) != leer64(idx + 88) {
        kprint(nombre)
        kprintln(cadena(": CRC32C del .tipos distinto del índice"))
        give false
    }
    each j among 0..n {
        hold off = leer64(idx + 128 + j * 16)
        hold len = leer64(idx + 136 + j * 16)
        when off < 0 || len < 1 || off + len > b {
            kprint(nombre)
            kprintln(cadena(": documento fuera de su archivo"))
            give false
        }
    }
    give true
}

// Carga y verifica f4/: índices, tipos, valida.bin entero (CRC32C), entrena.bin por
// tramos (CRC32C, sin dejarlo en RAM) y prompts.txt. Rellena la configuración.
flow cargarCorpus() => Bool {
    when !discoHayPermitida() || !fatMontar() {
        kprintln(cadena("enca=entrenar: no hay partición ELEDATOS FAT32"))
        give false
    }
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    change tamE = 0
    when fatAbrir(cadena("f4/entrena.idx")) { tamE = fatTamanoArchivo() }
    when tamE == 0 {
        kprintln(cadena("enca=entrenar: falta f4/entrena.idx (construir.ps1 -CorpusF4)"))
        give false
    }
    hold idxE = leerTodo(cadena("f4/entrena.idx"), -1)
    hold idxV = leerTodo(cadena("f4/valida.idx"), -1)
    when idxE == 0 || idxV == 0 {
        kprintln(cadena("enca=entrenar: no se pudo leer f4/entrena.idx o f4/valida.idx"))
        give false
    }
    hold nE = leer64(idxE + 16)
    hold nV = leer64(idxV + 16)
    hold tiposE = leerTodo(cadena("f4/entrena.tipos"), nE)
    hold tiposV = leerTodo(cadena("f4/valida.tipos"), nV)
    when tiposE == 0 || tiposV == 0 {
        kprintln(cadena("enca=entrenar: falta f4/entrena.tipos o f4/valida.tipos, o no miden lo del índice"))
        give false
    }
    when !verificarIndice(idxE, 128 + nE * 16, tiposE, cadena("f4/entrena.idx")) { give false }
    when !verificarIndice(idxV, 128 + nV * 16, tiposV, cadena("f4/valida.idx")) { give false }
    hold bE = leer64(idxE + 32)
    hold bV = leer64(idxV + 32)
    hold crcE = leer64(idxE + 40)
    hold crcV = leer64(idxV + 40)
    // valida.bin entero (2 MB) en RAM, con su CRC32C.
    hold valida = leerTodo(cadena("f4/valida.bin"), bV)
    when valida == 0 {
        kprintln(cadena("enca=entrenar: falta f4/valida.bin o no mide lo del índice"))
        give false
    }
    when crc32cSse(valida, bV) != crcV {
        kprintln(cadena("enca=entrenar: CRC32C de valida.bin distinto del índice"))
        give false
    }
    // entrena.bin: tamaño y CRC32C por tramos.
    kprint(cadena("verificando f4/entrena.bin ("))
    kprintEntero(bE)
    kprint(cadena(" B, CRC32C por tramos de 8 MiB) ... "))
    hold t1 = rdtsc()
    hold crc = crcGrande(cadena("f4/entrena.bin"), bE)
    when crc < 0 {
        kprintln(cadena("falta f4/entrena.bin o no mide lo del índice"))
        give false
    }
    when crc != crcE {
        kprintln(cadena("CRC32C de entrena.bin distinto del índice"))
        give false
    }
    kprint(cadena("correcto en "))
    kprintEntero((rdtsc() - t1) / cpm)
    kprintln(cadena(" ms"))
    // Prompts del protocolo de evaluación.
    hold prompts = leerTodo(cadena("f4/prompts.txt"), -1)
    when prompts == 0 {
        kprintln(cadena("enca=entrenar: falta f4/prompts.txt"))
        give false
    }
    change tamP = 0
    when fatAbrir(cadena("f4/prompts.txt")) { tamP = fatTamanoArchivo() }
    // Tabla de líneas (inicio, largo), sin "\r" ni líneas vacías.
    hold tab = montonReservar(MAX_PROMPTS * 16 + 64)
    change np = 0
    change ini = 0
    each i among 0..tamP + 1 {
        when i == tamP || leer8(prompts + i) == 10 {
            change fin = i
            when fin > ini && leer8(prompts + fin - 1) == 13 { fin -= 1 }
            when fin - ini > 1000 { fin = ini + 1000 }
            when fin > ini && np < MAX_PROMPTS {
                escribir64(tab + np * 16, prompts + ini)
                escribir64(tab + np * 16 + 8, fin - ini)
                np += 1
            }
            ini = i + 1
        }
    }
    when np < 1 {
        kprintln(cadena("enca=entrenar: f4/prompts.txt sin líneas"))
        give false
    }
    hold tabE = idxE + 128
    change maxdoc = 0
    each j among 0..nE {
        when leer64(tabE + j * 16 + 8) > maxdoc { maxdoc = leer64(tabE + j * 16 + 8) }
    }
    hold docCap = maxdoc + 2 * fatBytesPorCluster() + 1024
    hold docbuf = montonReservar(docCap)
    hold perm = montonReservar(nE * 8 + 64)
    when docbuf == 0 || perm == 0 {
        kprintln(cadena("enca=entrenar: sin memoria para el búfer de documentos"))
        give false
    }
    cfgSet(K_NE, nE)
    cfgSet(K_BE, bE)
    cfgSet(K_NV, nV)
    cfgSet(K_BV, bV)
    cfgSet(K_CRCE, crcE)
    cfgSet(K_CRCV, crcV)
    cfgSet(K_CRCP, crc32cSse(prompts, tamP))
    cfgSet(K_MAXDOC, maxdoc)
    cfgSet(K_TABE, tabE)
    cfgSet(K_TABV, idxV + 128)
    cfgSet(K_VALIDA, valida)
    cfgSet(K_TIPOS, tiposV)
    cfgSet(K_TIPOSE, tiposE)
    cfgSet(K_PROMPTS, prompts)
    cfgSet(K_TABPROMPTS, tab)
    cfgSet(K_NPROMPTS, np)
    cfgSet(K_DOCBUF, docbuf)
    cfgSet(K_DOCCAP, docCap)
    cfgSet(K_PERM, perm)
    kprint(cadena("corpus f4 verificado: entrena "))
    kprintEntero(nE)
    kprint(cadena(" documentos, "))
    kprintEntero(bE)
    kprint(cadena(" B (CRC32C "))
    kprintHex(crcE)
    kprint(cadena("); valida "))
    kprintEntero(nV)
    kprint(cadena(" documentos, "))
    kprintEntero(bV)
    kprint(cadena(" B (CRC32C "))
    kprintHex(crcV)
    kprint(cadena("); "))
    kprintEntero(np)
    kprint(cadena(" prompts; documento mayor "))
    kprintEntero(maxdoc)
    kprint(cadena(" B; "))
    kprintEntero((rdtsc() - t0) / cpm)
    kprintln(cadena(" ms en total"))
    give true
}

// El documento d de entrena.bin en el búfer de documentos; devuelve su dirección o 0.
flow leerDocumento(off: Int, len: Int) => Int {
    hold cl = fatBytesPorCluster()
    hold ini = off / cl * cl
    hold dentro = off - ini
    when !fatAbrir(cadena("f4/entrena.bin")) { give 0 }
    when fatLeer(ini, dentro + len, cfgGet(K_DOCBUF)) != dentro + len { give 0 }
    give cfgGet(K_DOCBUF) + dentro
}

// ---- orden de los documentos de una pasada ----------------------------------------------------

// Pasada 1: el orden del índice. Pasada p >= 2: una permutación determinista con
// PCG32 (semilla SEMILLA_PERM + p), Fisher-Yates. Deja en el cursor la semilla y el
// estado del PCG después de barajar.
flow armarPermutacion(pasada: Int) {
    hold n = cfgGet(K_NE)
    hold perm = cfgGet(K_PERM)
    each i among 0..n { escribir64(perm + i * 8, i) }
    hold g = reservar(16, 8)
    hold semilla = SEMILLA_PERM + pasada
    pcgSembrar(g, semilla, 54)
    when pasada >= 2 {
        change i = n - 1
        during i > 0 {
            hold j = pcgEntero(g, i + 1)
            hold a = leer64(perm + i * 8)
            escribir64(perm + i * 8, leer64(perm + j * 8))
            escribir64(perm + j * 8, a)
            i -= 1
        }
    }
    cabSet(W_SEMILLA, semilla)
    cabSet(W_PCG, leer64(g))
}

// ---- progreso por pantalla ----------------------------------------------------------------------

// Una línea de progreso. `parcial`: bytes de corpus equivalentes ya hechos del
// documento en curso (vigilia + 2 sueños = 3 fases).
flow imprimirLinea(parcial: Int) {
    hold cpm = tscCiclosPorMs()
    hold ahora = rdtsc() / cpm
    hold pasada = cabGet(W_PASADA)
    hold total = cfgGet(K_PASADAS)
    change meta = cfgGet(K_BE)
    hold lim = cfgGet(K_LIMITE)
    when lim > 0 && lim < meta { meta = lim }
    hold bp = cabGet(W_BPASADA) + parcial
    change dec = bp * 1000 / meta
    when dec > 1000 { dec = 1000 }
    hold tot = cabGet(W_BTOT) + parcial
    hold sesion = tot - cfgGet(K_B0)
    hold ms = ahora - cfgGet(K_T0) - cfgGet(K_FUERA)
    change bps = 0
    when ms > 0 { bps = sesion * 1000 / ms }
    kprint(cadena("[entrena] pasada "))
    kprintEntero(pasada)
    kprint(cadena("/"))
    kprintEntero(total)
    kprint(cadena(" "))
    imprimirDecimas(dec)
    kprint(cadena(" %  doc "))
    kprintEntero(cabGet(W_K))
    kprint(cadena("  "))
    imprimirDecimas(tot / 100000)
    kprint(cadena(" MB  acum "))
    when cabGet(W_BPASADA) > 0 {
        kprintDecimal(cabGetF(W_ACC) / Float(cabGet(W_BPASADA)), 3)
    } otherwise {
        kprint(cadena("-"))
    }
    kprint(cadena(" b/B  "))
    kprintEntero(bps)
    kprint(cadena(" B/s  transcurrido "))
    imprimirTiempo((ahora - cfgGet(K_T0)) / 1000)
    kprint(cadena("  resta ~"))
    when bps > 0 {
        change faltan = meta - bp
        when faltan < 0 { faltan = 0 }
        hold resta = faltan / bps
        change restaTotal = resta
        when total > pasada { restaTotal = resta + (total - pasada) * meta / bps }
        imprimirTiempo(restaTotal)
    } otherwise {
        kprint(cadena("?"))
    }
    kprint(cadena("  valida "))
    hold np = cabGet(W_NPUNTOS)
    when np > 0 {
        kprintDecimal(lf(recDir(np - 1, 3)), 4)
    } otherwise {
        kprint(cadena("-"))
    }
    kprint(cadena("  ckpt en "))
    change falta = (cfgGet(K_PROXCKPT) - ahora) / 60000
    when falta < 0 { falta = 0 }
    kprintEntero(falta)
    kprintln(cadena(" min"))
}

// Imprime la línea cada ~5 s.
flow progreso(parcial: Int) {
    hold t = rdtsc()
    when t < cfgGet(K_PROXLINEA) { give }
    cfgSet(K_PROXLINEA, t + 5000 * tscCiclosPorMs())
    imprimirLinea(parcial)
}

// ---- entrenar un documento ----------------------------------------------------------------------

// Vigilia + 2 sueños sobre el documento (len bytes en `texto`), igual que
// modeloVigilia / modeloSueno de enca=hablar pero por tramos para poder informar
// del progreso. Devuelve los bits de la mezcla de la vigilia (suma precuencial:
// el byte real antes de aprenderlo).
flow entrenarDocumento(m: Int, texto: Int, len: Int) => Float {
    metricasReiniciar(m)
    perfilFase(0)
    encaFijarReparto(leer64(m + 16), 115)
    modeloIniciarDocumento(m)
    each pos among 0..len {
        modeloPaso(m, leer8(texto + pos), true)
        when (pos & 1023) == 1023 { progreso((pos + 1) / 3) }
    }
    hold bits = lf(m + 88)
    each s among 0..2 {
        perfilFase(1)
        encaFijarReparto(leer64(m + 16), 200)
        modeloIniciarDocumento(m)
        each pos among 0..len {
            modeloPasoReplay(m, leer8(texto + pos))
            when (pos & 1023) == 1023 { progreso((len * (s + 1) + pos + 1) / 3) }
        }
    }
    give bits
}

// ---- evaluación en valida.bin ---------------------------------------------------------------------

// res (8 palabras): 0 bits de la mezcla (F), 1 bytes, 2 bits TEXTO (F), 3 bytes TEXTO,
// 4 bits DIALOGO (F), 5 bytes DIALOGO, 6 documentos.
flow resultado() => Int { give reservar(64, 8) }

// Evaluación congelada de valida.bin entero: cada documento con contexto nuevo, sin
// aprender (modeloMedirCongelado). Deja el resultado en resultado().
flow evaluarValida(m: Int) {
    hold r = resultado()
    each i among 0..8 { escribir64(r + i * 8, 0) }
    hold nV = cfgGet(K_NV)
    hold tab = cfgGet(K_TABV)
    hold valida = cfgGet(K_VALIDA)
    hold tipos = cfgGet(K_TIPOS)
    hold cpm = tscCiclosPorMs()
    change bits = 0.0
    change bitsT = 0.0
    change bitsD = 0.0
    change bytes = 0
    change bytesT = 0
    change bytesD = 0
    change proxima = rdtsc() + 5000 * cpm
    each d among 0..nV {
        hold off = leer64(tab + d * 16)
        hold len = leer64(tab + d * 16 + 8)
        metricasReiniciar(m)
        modeloMedirCongelado(m, valida + off, len)
        hold b = lf(m + 88)
        bits += b
        bytes += len
        when leer8(tipos + d) == 1 {
            bitsD += b
            bytesD += len
        } otherwise {
            bitsT += b
            bytesT += len
        }
        when rdtsc() >= proxima {
            proxima = rdtsc() + 5000 * cpm
            kprint(cadena("[valida] documento "))
            kprintEntero(d + 1)
            kprint(cadena("/"))
            kprintEntero(nV)
            kprint(cadena("  "))
            kprintEntero(bytes * 100 / cfgGet(K_BV))
            kprintln(cadena(" %"))
        }
    }
    ef(r, bits)
    escribir64(r + 8, bytes)
    ef(r + 16, bitsT)
    escribir64(r + 24, bytesT)
    ef(r + 32, bitsD)
    escribir64(r + 40, bytesD)
    escribir64(r + 48, nV)
}

// ---- generaciones fijas ------------------------------------------------------------------------------

flow comienzaConTu(p: Int, n: Int) => Bool {
    // "TÚ:" en UTF-8: 54 C3 9A 3A
    give n >= 4 && leer8(p) == 84 && leer8(p + 1) == 195 && leer8(p + 2) == 154 && leer8(p + 3) == 58
}

// Genera con el muestreo del protocolo (semilla 4242, T 0,5, top-k 0, top-p 1, pen y
// ventana de mzDefecto) a partir de `pref` (n bytes); añade los bytes generados a dst
// en pos y devuelve la nueva posición. Con `dialogo` se detiene en el primer '\n'.
flow generar(m: Int, pref: Int, n: Int, dialogo: Bool, dst: Int, pos: Int) => Int {
    mzDefecto()
    mzFijarTopK(0)
    mzFijarSemilla(SEMILLA_GEN)
    mzFijarTemp(0.5)
    mzIniciar(m, pref, n)
    change nb = 0
    change fin = false
    during nb < MAX_GEN && !fin {
        hold b = mzSiguiente(m, false)
        when dialogo && b == 10 {
            fin = true
        } otherwise {
            escribir8(dst + pos + nb, b)
            nb += 1
        }
    }
    give pos + nb
}

// Las generaciones de todos los prompts, en el formato de evaluacion.md; devuelve la
// posición final del texto.
flow generaciones(m: Int, dst: Int, pos0: Int) => Int {
    change pos = pos0
    hold np = cfgGet(K_NPROMPTS)
    hold tab = cfgGet(K_TABPROMPTS)
    hold pref = cfgGet(K_PREF)
    each i among 0..np {
        hold p = leer64(tab + i * 16)
        hold n = leer64(tab + i * 16 + 8)
        hold dialogo = comienzaConTu(p, n)
        pos = pCad(dst, pos, cadena("--- generacion "))
        when i + 1 < 10 { pos = pByte(dst, pos, 48) }
        pos = pInt(dst, pos, i + 1)
        when dialogo { pos = pCad(dst, pos, cadena(" (dialogo)\nPROMPT: ")) } otherwise { pos = pCad(dst, pos, cadena(" (texto)\nPROMPT: ")) }
        pos = pBytes(dst, pos, p, n)
        pos = pByte(dst, pos, 10)
        // Contexto: el prompt; en diálogo, el prompt + "\nENCA:".
        hold nc = pBytes(pref, 0, p, n)
        change cn = nc
        when dialogo {
            cn = pCad(pref, cn, cadena("\nENCA:"))
            pos = pCad(dst, pos, cadena("ENCA:"))
        }
        pos = generar(m, pref, cn, dialogo, dst, pos)
        pos = pByte(dst, pos, 10)
    }
    give pos
}

// ---- archivos de los puntos y la curva -----------------------------------------------------------------

flow rec83() => Int { give reservar(32, 8) }
flow recLargo() => Int { give reservar(32, 8) }

// Nombres Mnnnn.TXT en dos registros de cadena (8.3 con relleno y normal).
flow nombrarM(n: Int) {
    hold a = rec83()
    hold b = recLargo()
    escribir64(a, 11)
    escribir64(b, 9)
    hold cifras = reservar(8, 8)
    escribir8(cifras, 48 + (n / 1000) % 10)
    escribir8(cifras + 1, 48 + (n / 100) % 10)
    escribir8(cifras + 2, 48 + (n / 10) % 10)
    escribir8(cifras + 3, 48 + n % 10)
    escribir8(a + 8, 77)
    escribir8(b + 8, 77)
    each i among 0..4 {
        escribir8(a + 9 + i, leer8(cifras + i))
        escribir8(b + 9 + i, leer8(cifras + i))
    }
    each i among 0..3 { escribir8(a + 13 + i, 32) }
    escribir8(a + 16, 84)
    escribir8(a + 17, 88)
    escribir8(a + 18, 84)
    escribir8(b + 13, 46)
    escribir8(b + 14, 84)
    escribir8(b + 15, 88)
    escribir8(b + 16, 84)
}

// Línea de CURVA.LOG del punto i. bps < 0: sin velocidad ni hora (se regeneró).
flow lineaLog(dst: Int, pos0: Int, i: Int, bps: Int, ms: Int) => Int {
    change pos = pos0
    hold bytes = leer64(recDir(i, 0))
    pos = pInt(dst, pos, i + 1)
    pos = pByte(dst, pos, 32)
    pos = pDec(dst, pos, Float(bytes) / 1000000.0, 2)
    pos = pByte(dst, pos, 32)
    pos = pInt(dst, pos, bytes)
    pos = pByte(dst, pos, 32)
    pos = pInt(dst, pos, leer64(recDir(i, 1)))
    each j among 2..6 {
        pos = pByte(dst, pos, 32)
        pos = pDec(dst, pos, lf(recDir(i, j)), 4)
    }
    pos = pByte(dst, pos, 32)
    when bps < 0 { pos = pByte(dst, pos, 45) } otherwise { pos = pInt(dst, pos, bps) }
    pos = pByte(dst, pos, 32)
    when bps < 0 { pos = pByte(dst, pos, 45) } otherwise { pos = pInt(dst, pos, ms) }
    pos = pByte(dst, pos, 10)
    give pos
}

flow cabeceraLog(dst: Int, pos: Int) => Int {
    give pCad(dst, pos, cadena("# punto MB bytes pasada bits_acum bits_valida bits_texto bits_dialogo B_por_s ms_kernel\n"))
}

flow escribirLog() {
    hold ok = escribirRaiz(cadena("CURVA   LOG"), cadena("CURVA.LOG"), cfgGet(K_LOGBUF), cfgGet(K_LOGLEN))
    when !ok { kprintln(cadena("AVISO: no se pudo escribir CURVA.LOG")) }
}

// Tras reanudar: deja CURVA.LOG con la cabecera y las líneas de los `n` puntos del
// checkpoint (las de después, de una sesión cortada, se descartan; si el archivo no
// las tiene todas se regeneran desde la curva, sin velocidad ni hora).
flow ajustarLog(n: Int) {
    hold lb = cfgGet(K_LOGBUF)
    change largo = 0
    change bien = false
    when fatAbrir(cadena("CURVA.LOG")) {
        hold t = fatTamanoArchivo()
        when t > 0 && t < CAP_LOG - 1024 && fatLeer(0, t, lb) == t {
            // Posición tras la línea n + 1 (cabecera + n puntos).
            change lineas = 0
            change i = 0
            during i < t && lineas < n + 1 {
                when leer8(lb + i) == 10 { lineas += 1 }
                i += 1
            }
            when lineas == n + 1 {
                bien = true
                largo = i
            }
        }
    }
    when !bien {
        largo = cabeceraLog(lb, 0)
        each i among 0..n { largo = lineaLog(lb, largo, i, -1, 0) }
        kprintln(cadena("CURVA.LOG regenerado desde la curva del checkpoint (sin velocidad ni hora)"))
    }
    cfgSet(K_LOGLEN, largo)
    escribirLog()
}

// ---- checkpoint -------------------------------------------------------------------------------------------

// Serializa el estado de ENCA tras el bloque del cursor; devuelve los bytes del estado.
flow serializarEstado(m: Int) => Int {
    hold total = encaSerializar(m, cfgGet(K_BUF) + CAB_BYTES, cabGet(W_BTOT))
    when total == 0 {
        kprintln(cadena("entrenar: la configuración del modelo no es la C5; no se serializa"))
        give 0
    }
    cabSet(W_BESTADO, total)
    cfgSet(K_TOTAL, total)
    give total
}

// Escribe el búfer (cursor + curva + estado ya serializado) en la ranura que no tiene el
// último checkpoint válido. Imprime tiempo, MB/s y el CRC32C de los datos.
flow escribirCheckpoint() => Bool {
    hold cpm = tscCiclosPorMs()
    hold total = cfgGet(K_TOTAL)
    hold bytes = CAB_BYTES + total
    hold pa = ckptPasoRanura(CKPT_ENTRENA, 0)
    hold pb = ckptPasoRanura(CKPT_ENTRENA, 1)
    change paso = pa
    when pb > paso { paso = pb }
    when paso < 0 { paso = 0 }
    paso += 1
    kprint(cadena("checkpoint "))
    kprintEntero(paso)
    kprint(cadena(": escribiendo "))
    kprintEntero(bytes)
    kprint(cadena(" B (pasada "))
    kprintEntero(cabGet(W_PASADA))
    kprint(cadena(", documento "))
    kprintEntero(cabGet(W_K))
    kprint(cadena(", "))
    imprimirDecimas(cabGet(W_BTOT) / 100000)
    kprintln(cadena(" MB) ..."))
    hold t0 = rdtsc()
    hold bien = ckptGuardar(CKPT_ENTRENA, paso, cfgGet(K_BUF), bytes, false)
    hold t1 = rdtsc()
    cfgSet(K_FUERA, cfgGet(K_FUERA) + (t1 - t0) / cpm)
    cfgSet(K_PROXCKPT, t1 / cpm + cfgGet(K_MINUTOS) * 60000)
    when !bien {
        kprintln(cadena("checkpoint: FALLÓ la escritura (¿falta espacio en ELEDATOS?); el entrenamiento sigue sin él"))
        give false
    }
    cfgSet(K_NCKPT, cfgGet(K_NCKPT) + 1)
    hold r = ckptRanuraGuardada(CKPT_ENTRENA)
    kprint(cadena("checkpoint "))
    kprintEntero(paso)
    kprint(cadena(" guardado en la ranura "))
    when r == 0 { kprint(cadena("A")) } otherwise { kprint(cadena("B")) }
    kprint(cadena(": "))
    encaImprimirMsMBs(bytes, t1 - t0)
    kprint(cadena(", CRC32C de los datos "))
    kprintHex(ckptCrcRanura(CKPT_ENTRENA, r))
    kprintByte(10)
    give true
}

// Checkpoint periódico: serializa y escribe.
flow checkpoint(m: Int) {
    hold t0 = rdtsc()
    when serializarEstado(m) == 0 { give }
    cfgSet(K_FUERA, cfgGet(K_FUERA) + (rdtsc() - t0) / tscCiclosPorMs())
    escribirCheckpoint()
}

// ---- punto de evaluación -------------------------------------------------------------------------------------

flow puntoEvaluacion(m: Int) {
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    hold n = cabGet(W_NPUNTOS)
    when n >= MAX_PUNTOS {
        kprintln(cadena("curva llena: no se evalúan más puntos"))
        cabSet(W_PROXIMO, SIN_PUNTOS)
        checkpoint(m)
        give
    }
    kprint(cadena("punto de evaluación "))
    kprintEntero(n + 1)
    kprint(cadena(": "))
    imprimirDecimas(cabGet(W_BTOT) / 100000)
    kprint(cadena(" MB procesados (pasada "))
    kprintEntero(cabGet(W_PASADA))
    kprintln(cadena("); evaluando valida.bin congelada y las generaciones ..."))
    // Estado antes de evaluar.
    hold total = serializarEstado(m)
    when total == 0 { give }
    hold buf = cfgGet(K_BUF)
    hold crcAntes = crc32cSse(buf + CAB_BYTES, total)
    evaluarValida(m)
    hold r = resultado()
    hold bits = lf(r)
    hold bytes = leer64(r + 8)
    hold bpb = razon(bits, bytes)
    hold bpbT = razon(lf(r + 16), leer64(r + 24))
    hold bpbD = razon(lf(r + 32), leer64(r + 40))
    hold acum = razon(cabGetF(W_ACC), cabGet(W_BPASADA))
    hold tv = rdtsc()
    // Texto del punto.
    hold tx = cfgGet(K_TEXTO)
    change p = 0
    p = pCad(tx, p, cadena("ENCA evaluación\npaso: "))
    p = pInt(tx, p, n + 1)
    p = pCad(tx, p, cadena("\nMB procesados: "))
    p = pDec(tx, p, Float(cabGet(W_BTOT)) / 1000000.0, 2)
    p = pCad(tx, p, cadena(" ("))
    p = pInt(tx, p, cabGet(W_BTOT))
    p = pCad(tx, p, cadena(" bytes)\npasada: "))
    p = pInt(tx, p, cabGet(W_PASADA))
    p = pCad(tx, p, cadena("\nbits/byte acumulados de la pasada (precuencial): "))
    p = pDec(tx, p, acum, 4)
    p = pCad(tx, p, cadena("\ncorpus: entrena CRC32C "))
    p = pHex8(tx, p, cfgGet(K_CRCE))
    p = pCad(tx, p, cadena(", valida CRC32C "))
    p = pHex8(tx, p, cfgGet(K_CRCV))
    p = pCad(tx, p, cadena("\nvalida: "))
    p = pInt(tx, p, bytes)
    p = pCad(tx, p, cadena(" bytes, "))
    p = pInt(tx, p, cfgGet(K_NV))
    p = pCad(tx, p, cadena(" documentos\nbits/byte: "))
    p = pDec(tx, p, bpb, 4)
    p = pCad(tx, p, cadena("\nbits/byte TEXTO: "))
    p = pDec(tx, p, bpbT, 4)
    p = pCad(tx, p, cadena(" ("))
    p = pInt(tx, p, leer64(r + 24))
    p = pCad(tx, p, cadena(" bytes)\nbits/byte DIALOGO: "))
    p = pDec(tx, p, bpbD, 4)
    p = pCad(tx, p, cadena(" ("))
    p = pInt(tx, p, leer64(r + 40))
    p = pCad(tx, p, cadena(" bytes)\nmuestreo: semilla 4242, T 0,5, top-k 0, top-p 1,0, longitud 300\n"))
    p = generaciones(m, tx, p)
    mzDefecto()
    // La evaluación y las generaciones solo tocan campos transitorios (contexto del
    // mezclador, orden usado, ventana y potenciales de la corteza, que cada documento
    // reconstruye). Aun así se restaura el estado EXACTO de antes desde el búfer del
    // punto (que sigue intacto: es el que se guarda en el checkpoint) y se comprueba
    // volviendo a serializar.
    hold tr = rdtsc()
    when !encaDeserializar(m, buf + CAB_BYTES) {
        kprintln(cadena("entrenar: no se pudo restaurar el estado tras evaluar"))
        give
    }
    hold msRestaurar = (rdtsc() - tr) / cpm
    hold total2 = serializarEstado(m)
    when total2 == 0 { give }
    hold crcDespues = crc32cSse(buf + CAB_BYTES, total2)
    // Curva y cursor.
    hold rec = recDir(n, 0)
    escribir64(rec, cabGet(W_BTOT))
    escribir64(rec + 8, cabGet(W_PASADA))
    ef(rec + 16, acum)
    ef(rec + 24, bpb)
    ef(rec + 32, bpbT)
    ef(rec + 40, bpbD)
    escribir64(rec + 48, leer64(r + 24))
    escribir64(rec + 56, leer64(r + 40))
    cabSet(W_NPUNTOS, n + 1)
    change prox = cabGet(W_PROXIMO)
    during prox <= cabGet(W_BTOT) { prox += cabGet(W_EVAL) }
    cabSet(W_PROXIMO, prox)
    // Archivo del punto y línea de la curva.
    nombrarM(n + 1)
    when !escribirRaiz(rec83(), recLargo(), tx, p) {
        kprintln(cadena("AVISO: no se pudo escribir el archivo del punto (¿falta espacio o entradas en la raíz?)"))
    }
    hold ahora = rdtsc() / cpm
    hold ms = ahora - cfgGet(K_T0) - cfgGet(K_FUERA)
    change bps = 0
    when ms > 0 { bps = (cabGet(W_BTOT) - cfgGet(K_B0)) * 1000 / ms }
    cfgSet(K_LOGLEN, lineaLog(cfgGet(K_LOGBUF), cfgGet(K_LOGLEN), n, bps, ahora))
    escribirLog()
    kprint(cadena("  valida: "))
    kprintDecimal(bpb, 4)
    kprint(cadena(" bits/byte (TEXTO "))
    kprintDecimal(bpbT, 4)
    kprint(cadena(", DIALOGO "))
    kprintDecimal(bpbD, 4)
    kprint(cadena("); acumulado de la pasada "))
    kprintDecimal(acum, 4)
    kprint(cadena("; evaluación "))
    kprintEntero((tv - t0) / cpm)
    kprint(cadena(" ms; generaciones y archivo "))
    kprintEntero((rdtsc() - tv) / cpm)
    kprint(cadena(" ms; "))
    kprint(recLargo())
    kprintln(cadena(" y CURVA.LOG escritos"))
    kprint(cadena("  estado antes de evaluar y tras restaurarlo ("))
    kprintEntero(msRestaurar)
    kprint(cadena(" ms): CRC32C "))
    kprintHex(crcAntes)
    when crcAntes == crcDespues {
        kprintln(cadena(" = idéntico"))
    } otherwise {
        kprint(cadena(" frente a "))
        kprintHex(crcDespues)
        kprintln(cadena(": ¡DISTINTO! (la restauración no es exacta)"))
    }
    cfgSet(K_FUERA, cfgGet(K_FUERA) + (rdtsc() - t0) / cpm)
    // Checkpoint con el estado ya serializado (curva y estado coinciden).
    escribirCheckpoint()
}

// ---- reanudar o empezar --------------------------------------------------------------------------------------------

flow imprimirDiferencia(que: Int, guardado: Int, ahora: Int) {
    kprint(cadena("  incompatible: "))
    kprint(que)
    kprint(cadena(" guardado "))
    kprintEntero(guardado)
    kprint(cadena(", ahora "))
    kprintEntero(ahora)
    kprintByte(10)
}

// Compara la configuración guardada con la de ahora; true si coinciden.
flow compatible() => Bool {
    change bien = true
    when cabGet(W_MAGIA) != MAGIA_ENT || cabGet(W_VERSION) != VERSION_ENT {
        kprintln(cadena("  incompatible: magia o versión del cursor"))
        bien = false
    }
    when cabGet(W_RANURAS) != cfgGet(K_RANURAS) {
        imprimirDiferencia(cadena("ranuras por orden"), cabGet(W_RANURAS), cfgGet(K_RANURAS))
        bien = false
    }
    when cabGet(W_CRCE) != cfgGet(K_CRCE) || cabGet(W_BE) != cfgGet(K_BE) || cabGet(W_NE) != cfgGet(K_NE) {
        imprimirDiferencia(cadena("corpus de entrenamiento (CRC32C)"), cabGet(W_CRCE), cfgGet(K_CRCE))
        bien = false
    }
    when cabGet(W_CRCV) != cfgGet(K_CRCV) || cabGet(W_BV) != cfgGet(K_BV) || cabGet(W_NV) != cfgGet(K_NV) {
        imprimirDiferencia(cadena("corpus de validación (CRC32C)"), cabGet(W_CRCV), cfgGet(K_CRCV))
        bien = false
    }
    when cabGet(W_CRCP) != cfgGet(K_CRCP) {
        imprimirDiferencia(cadena("prompts.txt (CRC32C)"), cabGet(W_CRCP), cfgGet(K_CRCP))
        bien = false
    }
    when cabGet(W_EVAL) != cfgGet(K_EVAL) {
        imprimirDiferencia(cadena("bytes entre puntos de evaluación"), cabGet(W_EVAL), cfgGet(K_EVAL))
        bien = false
    }
    when cabGet(W_LIMITE) != cfgGet(K_LIMITE) {
        imprimirDiferencia(cadena("límite por pasada (bytes)"), cabGet(W_LIMITE), cfgGet(K_LIMITE))
        bien = false
    }
    when cabGet(W_BESTADO) != encaTamEstado() {
        imprimirDiferencia(cadena("bytes del estado de ENCA"), cabGet(W_BESTADO), encaTamEstado())
        bien = false
    }
    give bien
}

// Imprime la curva guardada.
flow imprimirCurva() {
    hold n = cabGet(W_NPUNTOS)
    when n == 0 {
        kprintln(cadena("  curva: aún sin puntos de evaluación"))
        give
    }
    kprintln(cadena("  curva de validación hasta aquí (punto: MB, pasada, bits/byte acumulados, valida, TEXTO, DIALOGO):"))
    each i among 0..n {
        kprint(cadena("   "))
        kprintEntero(i + 1)
        kprint(cadena(": "))
        imprimirDecimas(leer64(recDir(i, 0)) / 100000)
        kprint(cadena(" MB, pasada "))
        kprintEntero(leer64(recDir(i, 1)))
        each j among 2..6 {
            kprint(cadena(", "))
            kprintDecimal(lf(recDir(i, j)), 4)
        }
        kprintByte(10)
    }
}

// 0 = no hay entrenamiento guardado; 1 = reanudado; 2 = hay uno que no se puede usar.
flow reanudar(m: Int) => Int {
    hold cap = CAB_BYTES + encaTamEstado()
    change hay = false
    when fatAbrir(cadena("ENTREN_A.BIN")) { hay = true }
    when fatAbrir(cadena("ENTREN_B.BIN")) { hay = true }
    when !hay { give 0 }
    ckptConfigurar(CKPT_ENTRENA, cap)
    hold pa = ckptPasoRanura(CKPT_ENTRENA, 0)
    hold pb = ckptPasoRanura(CKPT_ENTRENA, 1)
    when pa < 0 && pb < 0 {
        kprintln(cadena("ENTREN_A/B.BIN existen pero ninguna tiene cabecera válida (¿corte en el primer checkpoint?): se empieza de cero"))
        give 0
    }
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    hold paso = ckptCargar(CKPT_ENTRENA, cfgGet(K_BUF))
    when paso < 0 {
        kprintln(cadena("ENTREN_A/B.BIN: hay cabecera válida pero los datos no cuadran con el CRC32C o no caben en esta configuración (otro número de ranuras)"))
        give 2
    }
    kprint(cadena("entrenamiento guardado: ranura "))
    when ckptRanuraCargada(CKPT_ENTRENA) == 0 { kprint(cadena("A")) } otherwise { kprint(cadena("B")) }
    kprint(cadena(", checkpoint "))
    kprintEntero(paso)
    kprint(cadena(", "))
    encaImprimirMsMBs(CAB_BYTES + cabGet(W_BESTADO), rdtsc() - t0)
    kprintln(cadena(" (lectura y CRC32C)"))
    when !compatible() {
        kprintln(cadena("el entrenamiento guardado no es compatible con las opciones o el corpus de ahora"))
        give 2
    }
    // La permutación de la pasada guardada debe salir igual (mismo PCG).
    hold pcgGuardado = cabGet(W_PCG)
    hold semGuardada = cabGet(W_SEMILLA)
    armarPermutacion(cabGet(W_PASADA))
    when cabGet(W_PCG) != pcgGuardado || cabGet(W_SEMILLA) != semGuardada {
        kprintln(cadena("la permutación de la pasada guardada no coincide con la regenerada (PCG distinto)"))
        give 2
    }
    when !encaDeserializar(m, cfgGet(K_BUF) + CAB_BYTES) {
        kprintln(cadena("no se pudo copiar el estado guardado al modelo"))
        give 2
    }
    kprint(cadena("REANUDA: pasada "))
    kprintEntero(cabGet(W_PASADA))
    kprint(cadena("/"))
    kprintEntero(cfgGet(K_PASADAS))
    kprint(cadena(", documento "))
    kprintEntero(cabGet(W_K))
    kprint(cadena("/"))
    kprintEntero(cfgGet(K_NE))
    kprint(cadena(", "))
    imprimirDecimas(cabGet(W_BTOT) / 100000)
    kprint(cadena(" MB procesados ("))
    kprintEntero(cabGet(W_BTOT))
    kprint(cadena(" B), bits/byte acumulados de la pasada "))
    kprintDecimal(razon(cabGetF(W_ACC), cabGet(W_BPASADA)), 4)
    when (cabGet(W_FLAGS) & 1) == 1 { kprint(cadena(" (ya terminado)")) }
    kprintByte(10)
    imprimirCurva()
    ajustarLog(cabGet(W_NPUNTOS))
    give 1
}

// Cursor nuevo; crea las ranuras.
flow empezar() => Bool {
    hold buf = cfgGet(K_BUF)
    each i among 0..CAB_BYTES / 8 { escribir64(buf + i * 8, 0) }
    cabSet(W_MAGIA, MAGIA_ENT)
    cabSet(W_VERSION, VERSION_ENT)
    cabSet(W_RANURAS, cfgGet(K_RANURAS))
    cabSet(W_CRCE, cfgGet(K_CRCE))
    cabSet(W_CRCV, cfgGet(K_CRCV))
    cabSet(W_NE, cfgGet(K_NE))
    cabSet(W_BE, cfgGet(K_BE))
    cabSet(W_NV, cfgGet(K_NV))
    cabSet(W_BV, cfgGet(K_BV))
    cabSet(W_CRCP, cfgGet(K_CRCP))
    cabSet(W_EVAL, cfgGet(K_EVAL))
    cabSet(W_LIMITE, cfgGet(K_LIMITE))
    cabSet(W_PASADAS, cfgGet(K_PASADAS))
    cabSet(W_PASADA, 1)
    when cfgGet(K_EVAL) > 0 { cabSet(W_PROXIMO, cfgGet(K_EVAL)) } otherwise { cabSet(W_PROXIMO, SIN_PUNTOS) }
    armarPermutacion(1)
    hold cap = CAB_BYTES + encaTamEstado()
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    when !ckptPreparar(CKPT_ENTRENA, cap) {
        kprintln(cadena("entrenar: no se pudieron crear ENTREN_A.BIN y ENTREN_B.BIN (¿falta espacio en ELEDATOS?)"))
        give false
    }
    // Cabeceras viejas fuera: un entrenamiento anterior (o restos de otro archivo en esos
    // clusters) no debe poder reanudarse por error.
    hold ceros = montonReservar(1024)
    when ceros == 0 { give false }
    each i among 0..128 { escribir64(ceros + i * 8, 0) }
    each r among 0..2 {
        change ok = false
        when r == 0 { ok = fatAbrir(cadena("ENTREN_A.BIN")) } otherwise { ok = fatAbrir(cadena("ENTREN_B.BIN")) }
        when !ok || !fatEscribir(0, 512, ceros) {
            kprintln(cadena("entrenar: no se pudo invalidar la cabecera de una ranura"))
            montonLiberar(ceros)
            give false
        }
    }
    montonLiberar(ceros)
    discoVaciar()
    kprint(cadena("entrenamiento nuevo: ranuras ENTREN_A.BIN y ENTREN_B.BIN creadas ("))
    kprintEntero(mib(cap))
    kprint(cadena(" MiB cada una) en "))
    kprintEntero((rdtsc() - t0) / cpm)
    kprintln(cadena(" ms"))
    // CURVA.LOG nuevo: solo la cabecera.
    cfgSet(K_LOGLEN, cabeceraLog(cfgGet(K_LOGBUF), 0))
    escribirLog()
    give true
}

// ---- bucle de entrenamiento -------------------------------------------------------------------------------------------

// Pasa a la pasada siguiente (cursor a cero; permutación nueva).
flow siguientePasada() {
    hold p = cabGet(W_PASADA) + 1
    cabSet(W_PASADA, p)
    cabSet(W_K, 0)
    cabSet(W_BPASADA, 0)
    cabSetF(W_ACC, 0.0)
    cabSet(W_FLAGS, cabGet(W_FLAGS) & (~1))
    armarPermutacion(p)
}

// Un documento: leerlo, entrenarlo, avanzar el cursor y, si toca, evaluar o hacer un
// checkpoint. false si no se pudo leer del disco.
flow procesarDocumento(m: Int) => Bool {
    hold k = cabGet(W_K)
    hold doc = leer64(cfgGet(K_PERM) + k * 8)
    hold off = leer64(cfgGet(K_TABE) + doc * 16)
    hold len = leer64(cfgGet(K_TABE) + doc * 16 + 8)
    hold texto = leerDocumento(off, len)
    when texto == 0 {
        kprint(cadena("entrenar: no se pudo leer el documento "))
        kprintEntero(doc)
        kprintln(cadena(" de f4/entrena.bin; se detiene (lo guardado en el último checkpoint sigue válido)"))
        give false
    }
    hold bits = entrenarDocumento(m, texto, len)
    cabSet(W_K, k + 1)
    cabSet(W_BPASADA, cabGet(W_BPASADA) + len)
    cabSet(W_BTOT, cabGet(W_BTOT) + len)
    cabSetF(W_ACC, cabGetF(W_ACC) + bits)
    when cabGet(W_BTOT) >= cabGet(W_PROXIMO) {
        puntoEvaluacion(m)
    } otherwise when ahoraMs() >= cfgGet(K_PROXCKPT) {
        checkpoint(m)
    }
    give true
}

// Fin de una pasada: resumen y, o bien la pasada siguiente (con checkpoint), o bien el
// final (evaluación final si no coincide con el último punto, y checkpoint final).
flow finDePasada(m: Int) {
    hold pasada = cabGet(W_PASADA)
    kprint(cadena("pasada "))
    kprintEntero(pasada)
    kprint(cadena(" terminada: "))
    kprintEntero(cabGet(W_K))
    kprint(cadena(" documentos, "))
    kprintEntero(cabGet(W_BPASADA))
    kprint(cadena(" B, bits/byte acumulados (precuencial) "))
    kprintDecimal(razon(cabGetF(W_ACC), cabGet(W_BPASADA)), 4)
    kprintByte(10)
    when pasada < cfgGet(K_PASADAS) {
        siguientePasada()
        kprint(cadena("empieza la pasada "))
        kprintEntero(pasada + 1)
        kprintln(cadena(" (permutación determinista con PCG32)"))
        checkpoint(m)
        give
    }
    cabSet(W_FLAGS, cabGet(W_FLAGS) | 1)
    hold np = cabGet(W_NPUNTOS)
    change hace = true
    when np > 0 && leer64(recDir(np - 1, 0)) == cabGet(W_BTOT) { hace = false }
    when hace {
        kprintln(cadena("evaluación final de validación:"))
        puntoEvaluacion(m)
    } otherwise {
        checkpoint(m)
    }
}

// Entrena hasta terminar todas las pasadas. false si se detuvo por un error.
flow bucle(m: Int) => Bool {
    change fin = false
    change bien = true
    during !fin && bien {
        hold flags = cabGet(W_FLAGS)
        hold pasada = cabGet(W_PASADA)
        hold lim = cfgGet(K_LIMITE)
        when pasada > cfgGet(K_PASADAS) {
            fin = true
        } otherwise when (flags & 1) == 1 {
            // Terminado en el estado guardado: si ahora se piden más pasadas, sigue.
            when pasada < cfgGet(K_PASADAS) { siguientePasada() } otherwise { fin = true }
        } otherwise when cabGet(W_K) >= cfgGet(K_NE) || (lim > 0 && cabGet(W_BPASADA) >= lim) {
            finDePasada(m)
        } otherwise {
            bien = procesarDocumento(m)
        }
    }
    give bien
}

// ---- arranque ---------------------------------------------------------------------------------------------------------------

// Ranuras por orden que caben: las pedidas o la mayor potencia de 2 que quepa (0 si
// ni 65536). Cuenta el modelo, el búfer del checkpoint (otro tanto), valida y el
// documento mayor.
flow elegirRanuras(pedidas: Int) => Int {
    change s = pedidas
    hold libres = disponible()
    hold fijo = cfgGet(K_BV) + cfgGet(K_DOCCAP) + CAB_BYTES + cfgGet(K_NE) * 8 + CAP_TEXTO + CAP_LOG + MARGEN
    during s >= 65536 {
        hold necesita = 2 * bytesModelo(s) + fijo
        when necesita <= libres { give s }
        kprint(cadena("  "))
        kprintEntero(s)
        kprint(cadena(" ranuras por orden no caben (necesita "))
        kprintEntero(mib(necesita))
        kprint(cadena(" MiB entre el modelo, el búfer del checkpoint y lo demás; libres "))
        kprintEntero(mib(libres))
        kprintln(cadena(" MiB): se baja a la mitad"))
        s = s / 2
    }
    give 0
}

expose flow entrenarArranque() {
    hold cpm = tscCiclosPorMs()
    hold inicio = rdtsc()
    cfgSet(K_RANURAS, opcionEntero(cadena("ent_ranuras"), RANURAS_DEF))
    cfgSet(K_MINUTOS, opcionEntero(cadena("ent_min"), 30))
    cfgSet(K_EVAL, opcionEntero(cadena("ent_mb"), 10) * 1000000)
    cfgSet(K_PASADAS, opcionEntero(cadena("ent_pasadas"), 1))
    cfgSet(K_LIMITE, opcionEntero(cadena("ent_limite"), 0) * 1000000)
    cfgSet(K_NUEVO, opcionEntero(cadena("ent_nuevo"), 0))
    hold retardo = opcionEntero(cadena("ent_retardo"), 0)
    ckptFijarRetardoPrueba(retardo)
    hold s0 = cfgGet(K_RANURAS)
    when cfgGet(K_PASADAS) < 1 { cfgSet(K_PASADAS, 1) }
    when cfgGet(K_MINUTOS) < 1 { cfgSet(K_MINUTOS, 1) }
    when s0 < 65536 || (s0 & (s0 - 1)) != 0 {
        kprintln(cadena("enca=entrenar: ent_ranuras debe ser una potencia de 2 >= 65536"))
        give
    }
    kprint(cadena("ENCA entrena (enca=entrenar): "))
    kprintEntero(s0)
    kprint(cadena(" ranuras por orden, checkpoint cada "))
    kprintEntero(cfgGet(K_MINUTOS))
    kprint(cadena(" min, punto de evaluación cada "))
    kprintEntero(cfgGet(K_EVAL) / 1000000)
    kprint(cadena(" MB, "))
    kprintEntero(cfgGet(K_PASADAS))
    kprint(cadena(" pasada(s)"))
    when cfgGet(K_LIMITE) > 0 {
        kprint(cadena(", límite "))
        kprintEntero(cfgGet(K_LIMITE) / 1000000)
        kprint(cadena(" MB por pasada"))
    }
    when cfgGet(K_NUEVO) != 0 { kprint(cadena(", ent_nuevo=1")) }
    when retardo > 0 {
        kprint(cadena(", PRUEBA: pausa de "))
        kprintEntero(retardo)
        kprint(cadena(" ms a mitad de cada checkpoint"))
    }
    kprintByte(10)
    when !cargarCorpus() {
        kprintln(cadena("enca=entrenar: sin corpus f4 utilizable; sigue el arranque normal"))
        give
    }
    kprint(cadena("memoria: "))
    kprintEntero(mib(disponible()))
    kprintln(cadena(" MiB disponibles"))
    hold s = elegirRanuras(s0)
    when s == 0 {
        kprintln(cadena("enca=entrenar: no hay memoria ni para 65536 ranuras por orden; no se entrena"))
        give
    }
    when s != s0 {
        kprint(cadena("AVISO: se usarán "))
        kprintEntero(s)
        kprint(cadena(" ranuras por orden en vez de "))
        kprintEntero(s0)
        kprintln(cadena(" (no caben en la memoria de esta máquina)"))
        cfgSet(K_RANURAS, s)
    }
    hold previo = encaPerfil()
    encaFijarRanurasEstado(s)
    hold cap = CAB_BYTES + encaTamEstado()
    hold buf = montonReservar(cap + 1024)
    hold logbuf = montonReservar(CAP_LOG)
    hold texto = montonReservar(CAP_TEXTO)
    hold pref = montonReservar(2048)
    when buf == 0 || logbuf == 0 || texto == 0 || pref == 0 {
        kprintln(cadena("enca=entrenar: sin memoria para el búfer del checkpoint"))
        encaFijarPerfil(previo)
        give
    }
    cfgSet(K_BUF, buf)
    cfgSet(K_LOGBUF, logbuf)
    cfgSet(K_TEXTO, texto)
    cfgSet(K_PREF, pref)
    hold tc = rdtsc()
    hold m = espCrearModelo(s)
    when m == 0 {
        kprintln(cadena("enca=entrenar: sin memoria para el modelo"))
        encaFijarPerfil(previo)
        give
    }
    cfgSet(K_MODELO, m)
    kprint(cadena("modelo creado: "))
    kprintEntero(s)
    kprint(cadena(" ranuras por orden, "))
    kprintEntero(mib(ncaBytesReservados()))
    kprint(cadena(" MiB reservados por ENCA en total, búfer del checkpoint "))
    kprintEntero(mib(cap))
    kprint(cadena(" MiB, "))
    kprintEntero((rdtsc() - tc) / cpm)
    kprint(cadena(" ms; libres ahora "))
    kprintEntero(mib(disponible()))
    kprintln(cadena(" MiB"))
    // Reanudar o empezar.
    change estado = 0
    when cfgGet(K_NUEVO) == 0 {
        estado = reanudar(m)
    } otherwise {
        kprintln(cadena("ent_nuevo=1: se ignora cualquier entrenamiento guardado"))
    }
    when estado == 2 {
        kprintln(cadena("enca=entrenar: NO se sobrescribe un entrenamiento guardado que no se puede reanudar; corrija las opciones o use ent_nuevo=1 para empezar de cero. Sigue el arranque normal."))
        encaFijarPerfil(previo)
        give
    }
    when estado == 0 {
        when !empezar() {
            encaFijarPerfil(previo)
            give
        }
    }
    cfgSet(K_T0, rdtsc() / cpm)
    cfgSet(K_FUERA, 0)
    cfgSet(K_B0, cabGet(W_BTOT))
    cfgSet(K_PROXLINEA, rdtsc() + 5000 * cpm)
    cfgSet(K_PROXCKPT, rdtsc() / cpm + cfgGet(K_MINUTOS) * 60000)
    kprintln(cadena("entrenando (vigilia + 2 sueños por documento; línea de progreso cada ~5 s) ..."))
    hold bien = bucle(m)
    hold segundos = (rdtsc() / cpm - cfgGet(K_T0)) / 1000
    when bien {
        kprint(cadena("entrenamiento terminado: "))
        kprintEntero(cabGet(W_BTOT))
        kprint(cadena(" B procesados en total; esta sesión "))
        kprintEntero(cabGet(W_BTOT) - cfgGet(K_B0))
        kprint(cadena(" B en "))
        imprimirTiempo(segundos)
        kprint(cadena(" ("))
        kprintEntero(cfgGet(K_NCKPT))
        kprint(cadena(" checkpoints, "))
        kprintEntero(cabGet(W_NPUNTOS))
        kprintln(cadena(" puntos de evaluación en la curva)"))
        kprint(cadena("  bits/byte de validación finales: "))
        when cabGet(W_NPUNTOS) > 0 {
            kprintDecimal(lf(recDir(cabGet(W_NPUNTOS) - 1, 3)), 4)
        } otherwise {
            kprint(cadena("-"))
        }
        kprintByte(10)
        // El modelo entrenado queda como modelo hablante de ENCA>.
        mzDefecto()
        encaFijarHablante(m, s, cabGet(W_BTOT))
    } otherwise {
        kprintln(cadena("enca=entrenar: el entrenamiento se detuvo por un error; el modelo en memoria no se registra"))
    }
    kprint(cadena("memoria al final: "))
    kprintEntero(mib(montonEnUso()))
    kprint(cadena(" MiB en uso del montón, "))
    kprintEntero(mib(ncaBytesReservados()))
    kprint(cadena(" MiB reservados por ENCA; tiempo total de enca=entrenar "))
    imprimirTiempo((rdtsc() - inicio) / cpm / 1000)
    kprintByte(10)
    encaFijarPerfil(previo)
}

// ---- arranque normal: usar un entrenamiento terminado ------------------------------------------------------------------------

// Con ENTREN_A/B.BIN válidas y un entrenamiento terminado, carga su modelo como
// hablante (tiene prioridad sobre HABLA_*: es el más largo). 0 = no hay (sin
// mensaje) o no está terminado; 1 = cargado; 2 = hay pero algo falló.
expose flow entrenarCargarTerminado() => Int {
    when !discoHayPermitida() || !fatMontar() { give 0 }
    change cap = 0
    when fatAbrir(cadena("ENTREN_A.BIN")) { cap = fatTamanoArchivo() }
    when fatAbrir(cadena("ENTREN_B.BIN")) && fatTamanoArchivo() > cap { cap = fatTamanoArchivo() }
    when cap <= 512 + CAB_BYTES { give 0 }
    cap = cap - 512
    ckptConfigurar(CKPT_ENTRENA, cap)
    hold buf = montonReservar(cap + 1024)
    when buf == 0 {
        kprintln(cadena("entrenamiento guardado: sin memoria para el búfer del estado"))
        give 2
    }
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    hold paso = ckptCargar(CKPT_ENTRENA, buf)
    hold t1 = rdtsc()
    when paso < 0 {
        kprintln(cadena("entrenamiento guardado: ENTREN_A/B.BIN sin ranura válida (cabecera o CRC32C); no se carga"))
        montonLiberar(buf)
        give 2
    }
    when leer64(buf) != MAGIA_ENT || leer64(buf + W_VERSION * 8) != VERSION_ENT {
        kprintln(cadena("entrenamiento guardado: magia o versión del cursor; no se carga"))
        montonLiberar(buf)
        give 2
    }
    when (leer64(buf + W_FLAGS * 8) & 1) == 0 {
        kprint(cadena("entrenamiento guardado sin terminar (pasada "))
        kprintEntero(leer64(buf + W_PASADA * 8))
        kprint(cadena(", "))
        kprintEntero(leer64(buf + W_BTOT * 8) / 1000000)
        kprintln(cadena(" MB): no se usa como modelo; para seguir, arranque con enca=entrenar"))
        montonLiberar(buf)
        give 0
    }
    hold s = leer64(buf + W_RANURAS * 8)
    when s < 65536 || s > 4194304 || (s & (s - 1)) != 0 {
        kprintln(cadena("entrenamiento guardado: ranuras por orden inválidas; no se carga"))
        montonLiberar(buf)
        give 2
    }
    hold previo = encaPerfil()
    encaFijarRanurasEstado(s)
    when !encaCabeceraCompatible(buf + CAB_BYTES) {
        kprintln(cadena("entrenamiento guardado: configuración distinta de la C5; no se carga"))
        encaFijarPerfil(previo)
        montonLiberar(buf)
        give 2
    }
    hold m = espCrearModelo(s)
    when m == 0 {
        kprintln(cadena("entrenamiento guardado: sin memoria para el modelo"))
        encaFijarPerfil(previo)
        montonLiberar(buf)
        give 2
    }
    hold t2 = rdtsc()
    when !encaDeserializar(m, buf + CAB_BYTES) {
        kprintln(cadena("entrenamiento guardado: no se pudo copiar el estado al modelo"))
        encaFijarPerfil(previo)
        montonLiberar(buf)
        give 2
    }
    hold t3 = rdtsc()
    hold total = leer64(buf + W_BESTADO * 8)
    kprint(cadena("modelo entrenado cargado de ENTREN_*.BIN: ranura "))
    when ckptRanuraCargada(CKPT_ENTRENA) == 0 { kprint(cadena("A")) } otherwise { kprint(cadena("B")) }
    kprint(cadena(", checkpoint "))
    kprintEntero(paso)
    kprint(cadena(", "))
    kprintEntero(mib(total))
    kprint(cadena(" MB en "))
    encaImprimirMsMBs(total, t1 - t0)
    kprint(cadena(" (lectura y CRC32C); copia al modelo "))
    kprintEntero((t3 - t2) / cpm)
    kprint(cadena(" ms; "))
    kprintEntero(s)
    kprint(cadena(" ranuras por orden, "))
    kprintEntero(leer64(buf + W_BTOT * 8))
    kprint(cadena(" B de corpus procesados en "))
    kprintEntero(leer64(buf + W_PASADA * 8))
    kprintln(cadena(" pasada(s)"))
    encaFijarHablante(m, s, leer64(buf + W_BTOT * 8))
    encaFijarPerfil(previo)
    montonLiberar(buf)
    give 1
}
