// ENCA: barrido de ranuras del hipocampo (opción de arranque enca=ranuras).
//
// Pregunta: cuánto mejora ENCA (bits/byte) al agrandar el hipocampo, cuánto
// cuesta (RAM, velocidad) y hasta dónde llega el hardware. Mide, en modo
// rápido y con la configuración C5 de siempre salvo las ranuras por orden S:
//   1. corpus ENCA (125 KB): entrena (vigilia + 2 sueños por archivo) y evalúa
//      las pruebas A y B congeladas;
//   2. corpus ELE (código fuente del compilador de ELE, ele/*.bin de la
//      partición de datos; ver herramientas/crear_corpus_ele.py): entrena
//      documento a documento igual y evalúa la prueba C congelada.
// Cada parte usa un modelo nuevo (un solo modelo vivo a la vez) y entre
// configuraciones se libera TODO lo del modelo (rastro de reservas de
// matematica.l). No escribe nada al disco.
//
// Opción: enca=ranuras (S = 65536 ... 4194304, duplicando) o
// enca=ranuras:262144,524288 (lista de S, para repartir el barrido en varias
// corridas). Termina con "ENCA ranuras: barrido terminado".

take nucleo.cpu
take nucleo.mem
take mem.fisica
take mem.monton
take lib.consola
take lib.matf64
take lib.crc32
take dispositivos.apic
take almacenamiento.disco
take almacenamiento.fat32
take arranque.limine
take enca.matematica
take enca.modelo
take enca.perfil
take enca.exp009

fixed ENTRENAMIENTO = 11
fixed ARCHIVOS = 18
fixed PRUEBA_A = 16
fixed MARGEN = 268435456            // 256 MiB que se dejan libres
fixed SOBRECOSTE = 4194304          // corteza, ventana, mezclador (~2,5 MiB) y holgura
fixed MAX_FILAS = 12
fixed PALABRAS_FILA = 32

// ---- opción de arranque ----------------------------------------------------

// Lista de S: +0 cuántas, +8 ... los valores.
flow lista() => Int { give reservar(8 + MAX_FILAS * 8, 8) }

flow esRanuras(v: Int) => Bool {
    when v == 0 { give false }
    when leer64(v) < 7 { give false }
    hold pal = cadena("ranuras")
    each i among 0..7 {
        when leer8(v + 8 + i) != leer8(pal + 8 + i) { give false }
    }
    when leer64(v) == 7 { give true }
    give leer8(v + 15) == 58
}

// true si la línea de órdenes pide el barrido (enca=ranuras[:lista]).
expose flow encaRanurasPedido() => Bool {
    give esRanuras(arranqueOpcion(cadena("enca")))
}

// Llena la lista de S desde la opción (o con la lista por defecto).
flow leerLista() {
    hold l = lista()
    escribir64(l, 0)
    hold v = arranqueOpcion(cadena("enca"))
    change usarDefecto = true
    when leer64(v) > 8 {
        change actual = 0
        change hay = false
        each i among 8..leer64(v) {
            hold b = leer8(v + 8 + i)
            when b >= 48 && b <= 57 {
                actual = actual * 10 + (b - 48)
                hay = true
            } otherwise {
                when hay && leer64(l) < MAX_FILAS {
                    escribir64(l + 8 + leer64(l) * 8, actual)
                    escribir64(l, leer64(l) + 1)
                }
                actual = 0
                hay = false
            }
        }
        when hay && leer64(l) < MAX_FILAS {
            escribir64(l + 8 + leer64(l) * 8, actual)
            escribir64(l, leer64(l) + 1)
        }
        when leer64(l) > 0 { usarDefecto = false }
    }
    when usarDefecto {
        hold s0 = 65536
        escribir64(l, 7)
        each i among 0..7 { escribir64(l + 8 + i * 8, s0 << i) }
    }
}

// ---- corpus ELE ------------------------------------------------------------

// Estado: +0 cargado (1), +8 índice (búfer), +16 entrena.bin, +24 prueba.bin,
// +32 documentos de entrenamiento, +40 de prueba, +48 bytes de entrena,
// +56 de prueba, +64 tabla de documentos.
flow ele() => Int { give reservar(80, 8) }

// Lee un archivo entero al montón; 0 si no existe o no se pudo leer.
flow leerArchivo(ruta: Int, tamEsperado: Int) => Int {
    when !fatAbrir(ruta) { give 0 }
    hold tam = fatTamanoArchivo()
    when tamEsperado >= 0 && tam != tamEsperado { give 0 }
    hold buf = montonReservar(tam + 64)
    when buf == 0 { give 0 }
    hold leidos = fatLeer(0, tam, buf)
    when leidos != tam {
        montonLiberar(buf)
        give 0
    }
    give buf
}

// 0 = verificado, 1 = ausente, 2 = incorrecto.
flow cargarEle() => Int {
    hold e = ele()
    when !discoHayPermitida() || !fatMontar() {
        kprintln(cadena("corpus ELE no encontrado: no hay partición ELEDATOS FAT32"))
        give 1
    }
    when !fatAbrir(cadena("ele/indice.bin")) {
        kprintln(cadena("corpus ELE no encontrado: falta ele/indice.bin (construir.ps1 -CorpusEle)"))
        give 1
    }
    hold tamIdx = fatTamanoArchivo()
    when tamIdx < 128 {
        kprintln(cadena("corpus ELE INCORRECTO: indice.bin demasiado corto"))
        give 2
    }
    hold idx = leerArchivo(cadena("ele/indice.bin"), -1)
    when idx == 0 {
        kprintln(cadena("corpus ELE INCORRECTO: no se pudo leer indice.bin"))
        give 2
    }
    when leer64(idx) != 0x3130584449454C45 || leer64(idx + 8) != 1 {
        kprintln(cadena("corpus ELE INCORRECTO: magia o versión de indice.bin"))
        give 2
    }
    when crc32cSse(idx, 72) != leer64(idx + 72) {
        kprintln(cadena("corpus ELE INCORRECTO: CRC32C de la cabecera del índice"))
        give 2
    }
    hold nE = leer64(idx + 16)
    hold nP = leer64(idx + 24)
    hold bE = leer64(idx + 32)
    hold bP = leer64(idx + 48)
    when nE < 1 || nP < 1 || tamIdx != 128 + (nE + nP) * 16 {
        kprintln(cadena("corpus ELE INCORRECTO: tamaño de indice.bin"))
        give 2
    }
    when crc32cSse(idx + 128, (nE + nP) * 16) != leer64(idx + 64) {
        kprintln(cadena("corpus ELE INCORRECTO: CRC32C de la tabla de documentos"))
        give 2
    }
    hold entrena = leerArchivo(cadena("ele/entrena.bin"), bE)
    hold prueba = leerArchivo(cadena("ele/prueba.bin"), bP)
    when entrena == 0 || prueba == 0 {
        kprintln(cadena("corpus ELE INCORRECTO: falta o no mide lo del índice entrena.bin / prueba.bin"))
        give 2
    }
    hold crcE = crc32cSse(entrena, bE)
    hold crcP = crc32cSse(prueba, bP)
    when crcE != leer64(idx + 40) || crcP != leer64(idx + 56) {
        kprintln(cadena("corpus ELE INCORRECTO: CRC32C de entrena.bin o prueba.bin distinto del índice"))
        give 2
    }
    // Cada documento dentro de su archivo.
    each j among 0..nE + nP {
        hold off = leer64(idx + 128 + j * 16)
        hold len = leer64(idx + 136 + j * 16)
        change tope = bE
        when j >= nE { tope = bP }
        when off < 0 || len < 0 || off + len > tope {
            kprintln(cadena("corpus ELE INCORRECTO: documento fuera de su archivo"))
            give 2
        }
    }
    escribir64(e, 1)
    escribir64(e + 8, idx)
    escribir64(e + 16, entrena)
    escribir64(e + 24, prueba)
    escribir64(e + 32, nE)
    escribir64(e + 40, nP)
    escribir64(e + 48, bE)
    escribir64(e + 56, bP)
    escribir64(e + 64, idx + 128)
    kprint(cadena("corpus ELE verificado: entrena "))
    kprintEntero(nE)
    kprint(cadena(" documentos, "))
    kprintEntero(bE)
    kprint(cadena(" B (CRC32C "))
    kprintHex(crcE)
    kprint(cadena("); prueba C "))
    kprintEntero(nP)
    kprint(cadena(" documentos, "))
    kprintEntero(bP)
    kprint(cadena(" B (CRC32C "))
    kprintHex(crcP)
    kprintln(cadena(")"))
    give 0
}

// ---- resultados por S ------------------------------------------------------
// Fila (32 palabras): 0 S  1 RAM del modelo (B)  2 cabe (1)
//  ENCA: 3 mezcla A 4 hipocampo A 5 corteza A 6 top-1 A 7 mezcla B 8 hip B
//        9 cor B 10 top-1 B  11 sobrescrituras  12 desalojos  13 ranuras ocupadas
//        14 B/s entrenamiento  15 B/s evaluación  16 ms crear  17 ms total
//  ELE:  18 mezcla C 19 hip C 20 cor C 21 top-1 C 22 sobrescrituras 23 desalojos
//        24 ocupadas 25 B/s entrenamiento 26 B/s evaluación 27 ms total
//        28 hay parte ELE (1)  29 ENCA completa (1)
flow filas() => Int { give reservar(MAX_FILAS * PALABRAS_FILA * 8, 8) }
flow fila(i: Int) => Int { give filas() + i * PALABRAS_FILA * 8 }

flow mib(bytes: Int) => Int { give bytes / 1048576 }

// Bytes que necesita un modelo de S ranuras por orden (5 órdenes, 12 sucesores):
// por ranura etiqueta, total y distintos (3 x 8) y 12 símbolos y 12 cuentas (24 x 8).
flow bytesModelo(s: Int) => Int { give 5 * s * (24 + 12 * 16) + SOBRECOSTE }

// Memoria que se puede usar: marcos físicos libres + montón libre (mapeado y
// sin uso, que se reutiliza).
flow disponible() => Int { give memFisicaLibres() * MARCO + montonMapeado() - montonEnUso() }

flow imprimirMemoria(etiqueta: Int) {
    kprint(etiqueta)
    kprint(cadena(": libres físicas "))
    kprintEntero(mib(memFisicaLibres() * MARCO))
    kprint(cadena(" MiB; montón mapeado "))
    kprintEntero(mib(montonMapeado()))
    kprint(cadena(" MiB, en uso "))
    kprintEntero(montonEnUso() / 1024)
    kprint(cadena(" KiB, libre en "))
    kprintEntero(montonBloquesLibres())
    kprint(cadena(" bloques (mayor "))
    kprintEntero(mib(montonMayorLibre()))
    kprint(cadena(" MiB); disponible "))
    kprintEntero(mib(disponible()))
    kprintln(cadena(" MiB"))
}

flow ocupadas(mem: Int) => Int {
    hold total = leer64(mem) * leer64(mem + 8)
    hold etiquetas = leer64(mem + 24)
    change n = 0
    each s among 0..total {
        when leer64(etiquetas + s * 8) != -1 { n += 1 }
    }
    give n
}

// Libera todo lo del modelo; devuelve true si el rastro estaba completo.
flow liberarModelo() => Bool {
    hold n = ncaLiberarRastreado()
    ncaRastrear(false)
    give n >= 0
}

flow velocidad(bytes: Int, ciclos: Int) => Int {
    when ciclos < 1 { give 0 }
    give bytes * tscCiclosPorMs() * 1000 / ciclos
}

// ---- parte 1: corpus ENCA ---------------------------------------------------
// 1 = completa, 0 = no cabe / falló.
flow parteEnca(f: Int, s: Int) => Int {
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    ncaRastrear(true)
    perfilReiniciar()
    hold base = ncaBytesReservados()
    hold m = modeloCrear(s, 1)
    when m == 0 {
        kprint(cadena("S="))
        kprintEntero(s)
        kprintln(cadena(": montonReservar devolvió 0 (el modelo no cabe)"))
        imprimirMemoria(cadena("  tras el fallo"))
        liberarModelo()
        give 0
    }
    hold tCrear = rdtsc() - t0
    hold ram = ncaBytesReservados() - base
    escribir64(f + 8, ram)
    escribir64(f + 128, tCrear / cpm)
    kprint(cadena("  modelo creado: "))
    kprintEntero(mib(ram))
    kprint(cadena(" MiB en "))
    kprintEntero(tCrear / cpm)
    kprintln(cadena(" ms"))

    change cVig = 0
    change cSue = 0
    change bytesE = 0
    each i among 0..ENTRENAMIENTO {
        hold tam = encaTamDe(i)
        hold a = rdtsc()
        modeloVigilia(m, encaTextoDe(i), tam)
        hold b = rdtsc()
        modeloSueno(m, encaTextoDe(i), tam)
        modeloSueno(m, encaTextoDe(i), tam)
        hold c = rdtsc()
        cVig += b - a
        cSue += c - b
        bytesE += tam
    }
    hold mem = leer64(m + 8)
    hold tEval0 = rdtsc()
    encaEvaluarSilencioso(m)
    hold r = encaResultado(1)
    hold ev = encaMedidasEval()
    hold cEval = leer64(ev + 16) - leer64(ev)
    hold cAuto = leer64(ev + 24) + leer64(ev + 32)
    hold bytesV = leer64(ev + 40) + leer64(ev + 48)
    // r: A en 0..24 (mezcla, hip, cor, top-1), B en 32..56.
    escribir64(f + 24, leer64(r))
    escribir64(f + 32, leer64(r + 8))
    escribir64(f + 40, leer64(r + 16))
    escribir64(f + 48, leer64(r + 24))
    escribir64(f + 56, leer64(r + 32))
    escribir64(f + 64, leer64(r + 40))
    escribir64(f + 72, leer64(r + 48))
    escribir64(f + 80, leer64(r + 56))
    escribir64(f + 88, leer64(mem + 80))
    escribir64(f + 96, leer64(mem + 88))
    escribir64(f + 104, ocupadas(mem))
    escribir64(f + 112, velocidad(bytesE, cVig + cSue))
    escribir64(f + 120, velocidad(bytesV, cEval - cAuto))
    escribir64(f + 136, (rdtsc() - t0) / cpm)
    escribir64(f + 232, 1)
    kprint(cadena("  ENCA entrenado: "))
    kprintEntero(bytesE)
    kprint(cadena(" B en "))
    kprintEntero((cVig + cSue) / cpm)
    kprint(cadena(" ms = "))
    kprintEntero(velocidad(bytesE, cVig + cSue))
    kprint(cadena(" B/s; evaluación "))
    kprintEntero(bytesV)
    kprint(cadena(" B en "))
    kprintEntero((cEval - cAuto) / cpm)
    kprint(cadena(" ms = "))
    kprintEntero(velocidad(bytesV, cEval - cAuto))
    kprint(cadena(" B/s (autocompletado "))
    kprintEntero(cAuto / cpm)
    kprintln(cadena(" ms)"))
    kprint(cadena("  A: mezcla "))
    kprintDecimal(lf(f + 24), 5)
    kprint(cadena(" hipocampo "))
    kprintDecimal(lf(f + 32), 5)
    kprint(cadena(" corteza "))
    kprintDecimal(lf(f + 40), 5)
    kprint(cadena(" top-1 "))
    kprintEntero(leer64(f + 48))
    kprint(cadena("; B: mezcla "))
    kprintDecimal(lf(f + 56), 5)
    kprint(cadena(" hipocampo "))
    kprintDecimal(lf(f + 64), 5)
    kprint(cadena(" corteza "))
    kprintDecimal(lf(f + 72), 5)
    kprint(cadena(" top-1 "))
    kprintEntero(leer64(f + 80))
    kprint(cadena("; sobrescrituras "))
    kprintEntero(leer64(f + 88))
    kprint(cadena(", desalojos "))
    kprintEntero(leer64(f + 96))
    kprint(cadena(", ranuras ocupadas "))
    kprintEntero(leer64(f + 104))
    kprint(cadena("/"))
    kprintEntero(5 * s)
    kprintByte(10)
    hold completo = liberarModelo()
    when !completo { kprintln(cadena("  AVISO: el rastro de reservas se desbordó (algo no se liberó)")) }
    give 1
}

// ---- parte 2: corpus ELE ----------------------------------------------------
flow parteEle(f: Int, s: Int) => Int {
    hold e = ele()
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    ncaRastrear(true)
    perfilReiniciar()
    hold base = ncaBytesReservados()
    hold m = modeloCrear(s, 1)
    when m == 0 {
        kprint(cadena("S="))
        kprintEntero(s)
        kprintln(cadena(": montonReservar devolvió 0 en la parte ELE"))
        imprimirMemoria(cadena("  tras el fallo"))
        liberarModelo()
        give 0
    }
    hold ram = ncaBytesReservados() - base
    when ram != leer64(f + 8) {
        kprint(cadena("  AVISO: RAM de la parte ELE distinta: "))
        kprintEntero(ram)
        kprint(cadena(" B frente a "))
        kprintEntero(leer64(f + 8))
        kprintln(cadena(" B"))
    }
    hold nE = leer64(e + 32)
    hold nP = leer64(e + 40)
    hold tabla = leer64(e + 64)
    hold ent = leer64(e + 16)
    hold pru = leer64(e + 24)
    change cVig = 0
    change cSue = 0
    change bytesE = 0
    each d among 0..nE {
        hold off = leer64(tabla + d * 16)
        hold len = leer64(tabla + d * 16 + 8)
        hold a = rdtsc()
        modeloVigilia(m, ent + off, len)
        hold b = rdtsc()
        modeloSueno(m, ent + off, len)
        modeloSueno(m, ent + off, len)
        hold c = rdtsc()
        cVig += b - a
        cSue += c - b
        bytesE += len
        when (d + 1) % 25 == 0 {
            kprint(cadena("    ELE entrenados "))
            kprintEntero(d + 1)
            kprint(cadena("/"))
            kprintEntero(nE)
            kprint(cadena(" documentos, "))
            kprintEntero(bytesE)
            kprint(cadena(" B, "))
            kprintEntero((rdtsc() - t0) / cpm / 1000)
            kprintln(cadena(" s"))
        }
    }
    hold mem = leer64(m + 8)
    // Prueba C congelada: sin aprender ni autocompletar.
    metricasReiniciar(m)
    change bytesC = 0
    hold ce0 = rdtsc()
    each d among 0..nP {
        hold off = leer64(tabla + (nE + d) * 16)
        hold len = leer64(tabla + (nE + d) * 16 + 8)
        modeloMedirCongelado(m, pru + off, len)
        bytesC += len
    }
    hold cEval = rdtsc() - ce0
    hold n = Float(leer64(m + 80))
    hold bm = lf(m + 88) / n
    hold bh = lf(m + 96) / n
    hold bc = lf(m + 104) / n
    hold top = leer64(m + 112) * 1000 / leer64(m + 80)
    ef(f + 144, bm)
    ef(f + 152, bh)
    ef(f + 160, bc)
    escribir64(f + 168, top)
    escribir64(f + 176, leer64(mem + 80))
    escribir64(f + 184, leer64(mem + 88))
    escribir64(f + 192, ocupadas(mem))
    escribir64(f + 200, velocidad(bytesE, cVig + cSue))
    escribir64(f + 208, velocidad(bytesC, cEval))
    escribir64(f + 216, (rdtsc() - t0) / cpm)
    escribir64(f + 224, 1)
    kprint(cadena("  ELE entrenado: "))
    kprintEntero(bytesE)
    kprint(cadena(" B en "))
    kprintEntero((cVig + cSue) / cpm)
    kprint(cadena(" ms = "))
    kprintEntero(velocidad(bytesE, cVig + cSue))
    kprint(cadena(" B/s; prueba C "))
    kprintEntero(bytesC)
    kprint(cadena(" B en "))
    kprintEntero(cEval / cpm)
    kprint(cadena(" ms = "))
    kprintEntero(velocidad(bytesC, cEval))
    kprintln(cadena(" B/s"))
    kprint(cadena("  C: mezcla "))
    kprintDecimal(bm, 5)
    kprint(cadena(" hipocampo "))
    kprintDecimal(bh, 5)
    kprint(cadena(" corteza "))
    kprintDecimal(bc, 5)
    kprint(cadena(" top-1 "))
    kprintEntero(top)
    kprint(cadena("; sobrescrituras "))
    kprintEntero(leer64(f + 176))
    kprint(cadena(", desalojos "))
    kprintEntero(leer64(f + 184))
    kprint(cadena(", ranuras ocupadas "))
    kprintEntero(leer64(f + 192))
    kprint(cadena("/"))
    kprintEntero(5 * s)
    kprintByte(10)
    hold completo = liberarModelo()
    when !completo { kprintln(cadena("  AVISO: el rastro de reservas se desbordó (algo no se liberó)")) }
    give 1
}

// ---- tabla final -------------------------------------------------------------
flow imprimirTabla(cuantas: Int) {
    kprintln(cadena("==== barrido de ranuras: corpus ENCA (pruebas A y B, bits/byte) ===="))
    kprintln(cadena("S por orden | RAM MiB | A mezcla | A hip | A cor | A top1 | B mezcla | B hip | B cor | B top1 | sobrescr. | ocup. % | entren. B/s | eval. B/s"))
    each i among 0..cuantas {
        hold f = fila(i)
        when leer64(f + 232) == 1 {
            kprintEntero(leer64(f))
            kprint(cadena(" | "))
            kprintEntero(mib(leer64(f + 8)))
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 24), 4)
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 32), 4)
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 40), 4)
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 48))
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 56), 4)
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 64), 4)
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 72), 4)
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 80))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 88))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 104) * 100 / (5 * leer64(f)))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 112))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 120))
            kprintByte(10)
        }
    }
    kprintln(cadena("==== barrido de ranuras: corpus ELE (prueba C, bits/byte) ===="))
    kprintln(cadena("S por orden | RAM MiB | C mezcla | C hip | C cor | C top1 | sobrescr. | desalojos | ocup. % | entren. B/s | eval. B/s | ms ENCA+ELE"))
    each i among 0..cuantas {
        hold f = fila(i)
        when leer64(f + 224) == 1 {
            kprintEntero(leer64(f))
            kprint(cadena(" | "))
            kprintEntero(mib(leer64(f + 8)))
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 144), 4)
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 152), 4)
            kprint(cadena(" | "))
            kprintDecimal(lf(f + 160), 4)
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 168))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 176))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 184))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 192) * 100 / (5 * leer64(f)))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 200))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 208))
            kprint(cadena(" | "))
            kprintEntero(leer64(f + 136))
            kprint(cadena("+"))
            kprintEntero(leer64(f + 216))
            kprintByte(10)
        }
    }
}

// ---- barrido ------------------------------------------------------------------
expose flow encaRanuras() {
    kprintln(cadena("ENCA ranuras: barrido del hipocampo en modo rápido (C5 salvo las ranuras por orden)"))
    when !encaCorpusListo() {
        kprintln(cadena("ENCA ranuras: sin corpus ENCA verificado (hito 16), no se mide nada"))
        kprintln(cadena("ENCA ranuras: barrido terminado"))
        give
    }
    hold hayEle = cargarEle() == 0
    when !hayEle { kprintln(cadena("ENCA ranuras: sin corpus ELE: solo la parte 1 (corpus ENCA)")) }
    leerLista()
    hold l = lista()
    kprint(cadena("ENCA ranuras: S por orden ="))
    each i among 0..leer64(l) {
        kprintByte(32)
        kprintEntero(leer64(l + 8 + i * 8))
    }
    kprintByte(10)
    imprimirMemoria(cadena("memoria al empezar"))
    hold cpm = tscCiclosPorMs()
    hold tInicio = rdtsc()
    change hechas = 0
    each i among 0..leer64(l) {
        hold s = leer64(l + 8 + i * 8)
        hold f = fila(i)
        escribir64(f, s)
        hold need = bytesModelo(s)
        hold libres = disponible()
        kprint(cadena("---- S = "))
        kprintEntero(s)
        kprint(cadena(" ranuras por orden ("))
        kprintEntero(5 * s)
        kprint(cadena(" en total) ----"))
        kprintByte(10)
        when need + MARGEN > libres {
            kprint(cadena("S="))
            kprintEntero(s)
            kprint(cadena(" no cabe (necesita "))
            kprintEntero(mib(need))
            kprint(cadena(" MiB, libres "))
            kprintEntero(mib(libres))
            kprintln(cadena(" MiB; margen de 256 MiB)"))
            leave
        }
        kprint(cadena("  el modelo necesita "))
        kprintEntero(mib(need))
        kprint(cadena(" MiB; "))
        imprimirMemoria(cadena("antes"))
        hold usoAntes = montonEnUso()
        hold r1 = parteEnca(f, s)
        when r1 == 0 { leave }
        hechas = i + 1
        imprimirMemoria(cadena("  tras liberar el modelo ENCA"))
        when montonEnUso() != usoAntes {
            kprint(cadena("  AVISO: el montón no volvió: en uso "))
            kprintEntero(montonEnUso())
            kprint(cadena(" B frente a "))
            kprintEntero(usoAntes)
            kprintln(cadena(" B"))
        } otherwise {
            kprintln(cadena("  el montón vuelve exactamente a su uso anterior"))
        }
        when hayEle {
            hold r2 = parteEle(f, s)
            when r2 == 0 { leave }
            imprimirMemoria(cadena("  tras liberar el modelo ELE"))
            when montonEnUso() != usoAntes {
                kprint(cadena("  AVISO: el montón no volvió: en uso "))
                kprintEntero(montonEnUso())
                kprint(cadena(" B frente a "))
                kprintEntero(usoAntes)
                kprintln(cadena(" B"))
            } otherwise {
                kprintln(cadena("  el montón vuelve exactamente a su uso anterior"))
            }
        }
        when montonVerificar() != 0 { kprintln(cadena("  AVISO: la lista libre del montón está dañada")) }
    }
    imprimirTabla(hechas)
    kprint(cadena("ENCA ranuras: "))
    kprintEntero(hechas)
    kprint(cadena(" de "))
    kprintEntero(leer64(l))
    kprint(cadena(" configuraciones medidas en "))
    kprintEntero((rdtsc() - tInicio) / cpm / 1000)
    kprintln(cadena(" s"))
    kprintln(cadena("ENCA ranuras: barrido terminado"))
}
