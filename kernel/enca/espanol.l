// ENCA aprende español (opción de arranque enca=hablar; ver enca/hablar.l).
//
// Corpus: es/{entrena,prueba,indice}.bin de la partición de datos (mismo formato
// que ele/: herramientas/crear_corpus_es.py; construir.ps1 -CorpusEs). Modelo
// "hablante": un modelo RÁPIDO aparte con la configuración C5 salvo las ranuras
// por orden (524288, o la mayor potencia de 2 que quepa). Se entrena documento
// a documento (vigilia + 2 sueños), se evalúa sobre la prueba congelada y se
// guarda en sus propias ranuras HABLA_A.BIN / HABLA_B.BIN (checkpoint.l, juego
// CKPT_HABLA, formato 2 con CRC32C; estado de ENCA con las ranuras en la
// cabecera, enca/estado.l).
//
// Pruebas congeladas del hablante (para :guardar, :deshacer y la comprobación
// al cargar), mismo esquema que las pruebas A y B de ENCA para que todo el
// código de aprender.l sirva sin cambios: un subconjunto fijo de prueba.bin,
// los primeros 700 bytes de cada documento (90 x 700 = 63 000 B); la prueba A
// son los documentos de índice par y la B los de índice impar. Las métricas
// van a encaResultado(1) en el mismo formato. La prueba completa (1,09 MB, ~20 s)
// solo se mide al final del entrenamiento, por fuente.

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
take almacenamiento.checkpoint
take enca.matematica
take enca.modelo
take enca.perfil
take enca.estado
take enca.exp009
take cpu.ifdiag

fixed RANURAS_HABLANTE = 524288
fixed MARGEN = 134217728            // 128 MiB que se dejan libres
fixed SOBRECOSTE = 4194304          // corteza, ventana, mezclador (~2,5 MiB) y holgura
fixed BYTES_SUBCONJUNTO = 700       // por documento de prueba
fixed CRC_PRUEBA = 0xF9E88C7E       // prueba.bin de corpus_es (completo y desarrollo)

// ---- corpus ------------------------------------------------------------------

// +0 cargado (1), +8 índice, +16 entrena.bin, +24 prueba.bin, +32 documentos de
// entrenamiento, +40 de prueba, +48 bytes de entrena, +56 de prueba, +64 tabla
// de documentos, +72 CRC32C entrena, +80 CRC32C prueba, +88 1 si solo se cargó
// la prueba (entrena.bin no).
flow corpus() => Int { give reservar(104, 8) }

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

// Fuente de cada documento de la prueba (90 documentos de prueba.bin de
// corpus_es): 0 Wikipedia, 1 teatro, 2 narrativa y poesía de Wikisource. El
// índice no lleva la fuente; esta tabla se derivó fuera del kernel (teatro y
// Wikipedia suman exactamente 386095 B y 451845 B, las cifras de
// ESTADISTICAS.md; narrativa y poesía van juntas) y solo vale con el CRC32C
// de prueba.bin de arriba.
flow fuentes() => Int {
    give cadena("020000002000021002200102002111111111111111111002000022222002222222222221110211111000022222")
}

flow hayFuentes() => Bool {
    hold e = corpus()
    give leer64(e) == 1 && leer64(e + 40) == 90 && leer64(e + 80) == CRC_PRUEBA
}

flow fuenteDe(d: Int) => Int {
    when !hayFuentes() { give 2 }
    give leer8(fuentes() + 8 + d) - 48
}

// 0 = verificado, 1 = ausente, 2 = incorrecto. `soloPrueba`: no carga
// entrena.bin (30 MB). `hablando`: imprime por qué falla (si no, en silencio
// cuando solo falta).
expose flow espCargarCorpus(soloPrueba: Bool, hablando: Bool) => Int {
    hold e = corpus()
    when leer64(e) == 1 && (soloPrueba || leer64(e + 88) == 0) { give 0 }
    when !discoHayPermitida() || !fatMontar() {
        when hablando { kprintln(cadena("corpus español no encontrado: no hay partición ELEDATOS FAT32")) }
        give 1
    }
    when !fatAbrir(cadena("es/indice.bin")) {
        when hablando { kprintln(cadena("corpus español no encontrado: falta es/indice.bin (construir.ps1 -CorpusEs)")) }
        give 1
    }
    hold tamIdx = fatTamanoArchivo()
    when tamIdx < 128 {
        kprintln(cadena("corpus español INCORRECTO: indice.bin demasiado corto"))
        give 2
    }
    hold idx = leerArchivo(cadena("es/indice.bin"), -1)
    when idx == 0 {
        kprintln(cadena("corpus español INCORRECTO: no se pudo leer indice.bin"))
        give 2
    }
    when leer64(idx) != 0x3130584449454C45 || leer64(idx + 8) != 1 {
        kprintln(cadena("corpus español INCORRECTO: magia o versión de indice.bin"))
        give 2
    }
    when crc32cSse(idx, 72) != leer64(idx + 72) {
        kprintln(cadena("corpus español INCORRECTO: CRC32C de la cabecera del índice"))
        give 2
    }
    hold nE = leer64(idx + 16)
    hold nP = leer64(idx + 24)
    hold bE = leer64(idx + 32)
    hold bP = leer64(idx + 48)
    when nE < 1 || nP < 1 || tamIdx != 128 + (nE + nP) * 16 {
        kprintln(cadena("corpus español INCORRECTO: tamaño de indice.bin"))
        give 2
    }
    when crc32cSse(idx + 128, (nE + nP) * 16) != leer64(idx + 64) {
        kprintln(cadena("corpus español INCORRECTO: CRC32C de la tabla de documentos"))
        give 2
    }
    change entrena = 0
    when !soloPrueba {
        entrena = leerArchivo(cadena("es/entrena.bin"), bE)
        when entrena == 0 {
            kprintln(cadena("corpus español INCORRECTO: falta o no mide lo del índice es/entrena.bin"))
            give 2
        }
    }
    hold prueba = leerArchivo(cadena("es/prueba.bin"), bP)
    when prueba == 0 {
        when hablando { kprintln(cadena("corpus español INCORRECTO: falta o no mide lo del índice es/prueba.bin")) }
        give 2
    }
    hold crcP = crc32cSse(prueba, bP)
    change crcE = 0
    when crcP != leer64(idx + 56) {
        kprintln(cadena("corpus español INCORRECTO: CRC32C de prueba.bin distinto del índice"))
        give 2
    }
    when !soloPrueba {
        crcE = crc32cSse(entrena, bE)
        when crcE != leer64(idx + 40) {
            kprintln(cadena("corpus español INCORRECTO: CRC32C de entrena.bin distinto del índice"))
            give 2
        }
    }
    // Cada documento dentro de su archivo.
    each j among 0..nE + nP {
        hold off = leer64(idx + 128 + j * 16)
        hold len = leer64(idx + 136 + j * 16)
        change tope = bE
        when j >= nE { tope = bP }
        when off < 0 || len < 0 || off + len > tope {
            kprintln(cadena("corpus español INCORRECTO: documento fuera de su archivo"))
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
    escribir64(e + 72, crcE)
    escribir64(e + 80, crcP)
    when soloPrueba { escribir64(e + 88, 1) } otherwise { escribir64(e + 88, 0) }
    when hablando {
        when soloPrueba {
            kprint(cadena("corpus español verificado (solo la prueba): "))
        } otherwise {
            kprint(cadena("corpus español verificado: entrena "))
            kprintEntero(nE)
            kprint(cadena(" documentos, "))
            kprintEntero(bE)
            kprint(cadena(" B (CRC32C "))
            kprintHex(crcE)
            kprint(cadena("); "))
        }
        kprint(cadena("prueba "))
        kprintEntero(nP)
        kprint(cadena(" documentos, "))
        kprintEntero(bP)
        kprint(cadena(" B (CRC32C "))
        kprintHex(crcP)
        kprintln(cadena(")"))
    }
    give 0
}

expose flow espHayPrueba() => Bool { give leer64(corpus()) == 1 }

// ---- memoria -------------------------------------------------------------------

// Bytes de un modelo de s ranuras por orden (5 órdenes, 12 sucesores): por
// ranura etiqueta, total y distintos (3 x 8) y 12 símbolos y 12 cuentas (24 x 8).
flow bytesModelo(s: Int) => Int { give 5 * s * (24 + 12 * 16) + SOBRECOSTE }

flow mib(bytes: Int) => Int { give bytes / 1048576 }

// Marcos físicos libres + montón libre (mapeado y sin uso, que se reutiliza).
flow disponible() => Int { give memFisicaLibres() * MARCO + montonMapeado() - montonEnUso() }

// Ranuras por orden del hablante: 524288 o la mayor potencia de 2 que quepa con
// el modelo, el búfer del estado (del tamaño del modelo, para guardar y para
// :guardar) y el margen. 0 si ni 65536 caben.
flow elegirRanuras(bytesCorpus: Int) => Int {
    change s = RANURAS_HABLANTE
    hold libres = disponible()
    during s >= 65536 {
        hold necesita = 2 * bytesModelo(s) + bytesCorpus + MARGEN
        when necesita <= libres { give s }
        kprint(cadena("  "))
        kprintEntero(s)
        kprint(cadena(" ranuras por orden no caben (necesita "))
        kprintEntero(mib(necesita))
        kprint(cadena(" MiB entre el modelo, el búfer del estado y el corpus, libres "))
        kprintEntero(mib(libres))
        kprintln(cadena(" MiB): se baja a la mitad"))
        s = s / 2
    }
    give 0
}

// ---- evaluación ----------------------------------------------------------------

// Escribe en encaResultado(1) las métricas de una prueba (p = 0 A, 1 B) a partir
// de las métricas del modelo, en el formato de exp009.informar (autocompletado a 0).
flow anotarPrueba(m: Int, p: Int) {
    hold n = Float(leer64(m + 80))
    hold res = encaResultado(1) + p * 32
    ef(res, lf(m + 88) / n)
    ef(res + 8, lf(m + 96) / n)
    ef(res + 16, lf(m + 104) / n)
    escribir64(res + 24, leer64(m + 112) * 1000 / leer64(m + 80))
    hold base = encaResultado(1)
    escribir64(base + 120 + p * 8, 0)
    escribir64(base + 144 + p * 8, 0)
    escribir64(base + 160 + p * 8, 0)
    escribir64(base + 176 + p * 8, 0)
}

// Evalúa las pruebas congeladas A y B del hablante (ver la cabecera), sin
// imprimir ni aprender; deja las métricas en encaResultado(1). Devuelve los
// bytes evaluados.
expose flow espEvaluarSilencioso(m: Int) => Int {
    hold e = corpus()
    hold nP = leer64(e + 40)
    hold nE = leer64(e + 32)
    hold tabla = leer64(e + 64)
    hold pru = leer64(e + 24)
    change total = 0
    each p among 0..2 {
        metricasReiniciar(m)
        each d among 0..nP {
            when d % 2 == p {
                hold off = leer64(tabla + (nE + d) * 16)
                change len = leer64(tabla + (nE + d) * 16 + 8)
                when len > BYTES_SUBCONJUNTO { len = BYTES_SUBCONJUNTO }
                modeloMedirCongelado(m, pru + off, len)
            }
        }
        ifVigilar(cadena("evalP"))
        total += leer64(m + 80)
        anotarPrueba(m, p)
    }
    give total
}

// Filas (64 bytes): +0 bytes, +8 bits de la mezcla (F), +16 del hipocampo (F),
// +24 de la corteza (F), +32 aciertos top-1, +40 documentos. Fuente 0..2 y la 3 = total.
flow filas() => Int { give reservar(4 * 64, 8) }

flow nombreFuente(g: Int) => Int {
    when g == 0 { give cadena("Wikipedia") }
    when g == 1 { give cadena("teatro (Wikisource)") }
    when g == 2 { give cadena("narrativa y poesía (Wikisource)") }
    give cadena("TOTAL")
}

flow imprimirFila(g: Int) {
    hold f = filas() + g * 64
    hold n = leer64(f)
    when n < 1 { give }
    hold nf = Float(n)
    kprint(cadena("  "))
    kprint(nombreFuente(g))
    kprint(cadena(": "))
    kprintEntero(leer64(f + 40))
    kprint(cadena(" documentos, "))
    kprintEntero(n)
    kprint(cadena(" B; mezcla "))
    kprintDecimal(lf(f + 8) / nf, 4)
    kprint(cadena(" bits/byte, hipocampo "))
    kprintDecimal(lf(f + 16) / nf, 4)
    kprint(cadena(", corteza "))
    kprintDecimal(lf(f + 24) / nf, 4)
    kprint(cadena(", top-1 "))
    kprintEntero(leer64(f + 32) * 1000 / n)
    kprintln(cadena(" por mil"))
}

// Prueba completa congelada (prueba.bin entero), por fuente si se conoce, e
// imprime la tabla y las referencias de gzip y xz. Devuelve la mezcla total (bits/byte).
expose flow espEvaluarCompleto(m: Int) => Float {
    hold e = corpus()
    hold nP = leer64(e + 40)
    hold nE = leer64(e + 32)
    hold tabla = leer64(e + 64)
    hold pru = leer64(e + 24)
    hold f0 = filas()
    each i among 0..32 { escribir64(f0 + i * 8, 0) }
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    each d among 0..nP {
        hold off = leer64(tabla + (nE + d) * 16)
        hold len = leer64(tabla + (nE + d) * 16 + 8)
        metricasReiniciar(m)
        modeloMedirCongelado(m, pru + off, len)
        hold g = fuenteDe(d)
        each k among 0..2 {
            change fila = f0 + 3 * 64
            when k == 0 { fila = f0 + g * 64 }
            escribir64(fila, leer64(fila) + leer64(m + 80))
            ef(fila + 8, lf(fila + 8) + lf(m + 88))
            ef(fila + 16, lf(fila + 16) + lf(m + 96))
            ef(fila + 24, lf(fila + 24) + lf(m + 104))
            escribir64(fila + 32, leer64(fila + 32) + leer64(m + 112))
            escribir64(fila + 40, leer64(fila + 40) + 1)
        }
    }
    hold ciclos = rdtsc() - t0
    kprintln(cadena("prueba completa congelada (prueba.bin), bits por byte:"))
    when hayFuentes() {
        each g among 0..3 { imprimirFila(g) }
    }
    imprimirFila(3)
    hold total = filas() + 3 * 64
    kprint(cadena("  evaluación: "))
    kprintEntero(leer64(total))
    kprint(cadena(" B en "))
    kprintEntero(ciclos / cpm)
    kprint(cadena(" ms = "))
    when ciclos > 0 { kprintEntero(leer64(total) * cpm * 1000 / ciclos) }
    kprintln(cadena(" B/s"))
    kprintln(cadena("  referencias sobre prueba.bin (1092883 B): gzip -9 3,080 bits/byte; xz -9 2,612; xz condicional al entrenamiento completo 2,238 (al de desarrollo 2,407)"))
    when leer64(total) < 1 { give 0.0 }
    give lf(total + 8) / Float(leer64(total))
}

// Resumen por fuente de la última prueba completa, para hablar.l y la bitácora:
// bits/byte de la mezcla de la fuente g (0..2) o del total (3).
expose flow espBitsFuente(g: Int) => Float {
    hold f = filas() + g * 64
    when leer64(f) < 1 { give 0.0 }
    give lf(f + 8) / Float(leer64(f))
}

// ---- entrenamiento ----------------------------------------------------------------

// Estadísticas del último entrenamiento: +0 bytes, +8 ciclos de vigilia,
// +16 de sueño, +24 ciclos totales.
flow estadisticas() => Int { give reservar(32, 8) }

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

// Entrena `m` con entrena.bin documento a documento (vigilia + 2 sueños) y
// muestra el progreso cada ~1 MB. Devuelve los bytes entrenados.
expose flow espEntrenar(m: Int) => Int {
    hold e = corpus()
    hold nE = leer64(e + 32)
    hold bE = leer64(e + 48)
    hold tabla = leer64(e + 64)
    hold ent = leer64(e + 16)
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    change cVig = 0
    change cSue = 0
    change bytes = 0
    change proximo = 1000000
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
        bytes += len
        when bytes >= proximo || d + 1 == nE {
            hold ms = (rdtsc() - t0) / cpm
            kprint(cadena("  entrenados "))
            kprintEntero(bytes)
            kprint(cadena(" B de "))
            kprintEntero(bE)
            kprint(cadena(" ("))
            kprintEntero(bytes * 100 / bE)
            kprint(cadena(" %), documento "))
            kprintEntero(d + 1)
            kprint(cadena("/"))
            kprintEntero(nE)
            kprint(cadena(", "))
            change bps = 0
            when ms > 0 { bps = bytes * 1000 / ms }
            kprintEntero(bps)
            kprint(cadena(" B/s, transcurrido "))
            imprimirTiempo(ms / 1000)
            kprint(cadena(", restante ~"))
            when bps > 0 { imprimirTiempo((bE - bytes) / bps) } otherwise { kprint(cadena("?")) }
            kprintByte(10)
            during proximo <= bytes { proximo += 1000000 }
        }
    }
    hold s = estadisticas()
    escribir64(s, bytes)
    escribir64(s + 8, cVig)
    escribir64(s + 16, cSue)
    escribir64(s + 24, rdtsc() - t0)
    give bytes
}

expose flow espBytesEntrenamiento() => Int { give leer64(corpus() + 48) }
expose flow espMsEntrenamiento() => Int { give leer64(estadisticas() + 24) / tscCiclosPorMs() }

// ---- guardar y cargar el hablante ----------------------------------------------------

flow letra(r: Int) {
    when r == 0 { kprint(cadena("A")) } otherwise { kprint(cadena("B")) }
}

// Paso siguiente al más alto que haya en las ranuras HABLA_A/B (1 si no hay).
expose flow espPasoSiguiente() => Int {
    ckptConfigurar(CKPT_HABLA, encaTamEstado())
    hold pa = ckptPasoRanura(CKPT_HABLA, 0)
    hold pb = ckptPasoRanura(CKPT_HABLA, 1)
    change p = pa
    when pb > p { p = pb }
    when p < 0 { give 1 }
    give p + 1
}

// Serializa el hablante y lo guarda como `paso` en la ranura que no tiene el
// último estado válido; `preparar` crea antes HABLA_A.BIN y HABLA_B.BIN. Las
// métricas de la cabecera son las de encaResultado(1) (la última evaluación
// congelada). Imprime el tiempo y los MB/s.
expose flow espGuardarHablante(m: Int, paso: Int, preparar: Bool, entrenados: Int) => Bool {
    hold cpm = tscCiclosPorMs()
    hold cap = encaTamEstado()
    hold buf = montonReservar(cap + 1024)
    when buf == 0 {
        kprintln(cadena("estado hablante: sin memoria para el búfer del estado"))
        give false
    }
    hold ts0 = rdtsc()
    hold total = encaSerializar(m, buf, entrenados)
    hold ts1 = rdtsc()
    when total == 0 {
        kprintln(cadena("estado hablante: la configuración del modelo no es la C5, no se guarda"))
        montonLiberar(buf)
        give false
    }
    encaMetricasAlBufer(buf)
    when preparar {
        hold tp0 = rdtsc()
        when !ckptPreparar(CKPT_HABLA, total) {
            kprintln(cadena("estado hablante: no se pudieron crear HABLA_A.BIN y HABLA_B.BIN (¿falta espacio en ELEDATOS?)"))
            montonLiberar(buf)
            give false
        }
        kprint(cadena("estado hablante: ranuras HABLA_A.BIN y HABLA_B.BIN creadas ("))
        kprintEntero(mib(total))
        kprint(cadena(" MiB cada una) en "))
        kprintEntero((rdtsc() - tp0) / cpm)
        kprintln(cadena(" ms"))
    }
    hold t0 = rdtsc()
    hold bien = ckptGuardar(CKPT_HABLA, paso, buf, total, false)
    hold t1 = rdtsc()
    montonLiberar(buf)
    when !bien {
        kprintln(cadena("estado hablante: FALLÓ el guardado"))
        give false
    }
    kprint(cadena("estado hablante guardado: paso "))
    kprintEntero(paso)
    kprint(cadena(" en la ranura "))
    letra(ckptRanuraGuardada(CKPT_HABLA))
    kprint(cadena(", "))
    kprintEntero(total)
    kprint(cadena(" bytes; serializar "))
    kprintEntero((ts1 - ts0) / cpm)
    kprint(cadena(" ms; escritura con CRC32C y vaciado "))
    encaImprimirMsMBs(total, t1 - t0)
    kprintByte(10)
    ckptImprimirDesglose(ts1 - ts0)
    give true
}

// Crea el modelo hablante (C5 en modo rápido, s ranuras por orden). 0 si no cabe.
expose flow espCrearModelo(s: Int) => Int {
    perfilReiniciar()
    give modeloCrear(s, 1)
}

// Entrena (si hace falta ya cargado el corpus), evalúa y guarda el hablante;
// lo deja registrado como modelo hablante. true si todo salió bien. El perfil
// activo no cambia.
expose flow espEntrenarYGuardar() => Bool {
    hold e = corpus()
    hold bE = leer64(e + 48)
    hold cpm = tscCiclosPorMs()
    hold tInicio = rdtsc()
    kprint(cadena("memoria: "))
    kprintEntero(mib(disponible()))
    kprint(cadena(" MiB disponibles; el modelo de "))
    kprintEntero(RANURAS_HABLANTE)
    kprint(cadena(" ranuras por orden necesita "))
    kprintEntero(mib(bytesModelo(RANURAS_HABLANTE)))
    kprintln(cadena(" MiB (y otro tanto el búfer del estado al guardar)"))
    hold s = elegirRanuras(bE)
    when s == 0 {
        kprintln(cadena("enca=hablar: no hay memoria ni para 65536 ranuras por orden; no se entrena"))
        give false
    }
    when s != RANURAS_HABLANTE {
        kprint(cadena("AVISO: el hablante usará "))
        kprintEntero(s)
        kprint(cadena(" ranuras por orden en vez de "))
        kprintEntero(RANURAS_HABLANTE)
        kprintln(cadena(" (no cabe en la memoria de esta máquina)"))
    }
    hold previo = encaPerfil()
    hold tc = rdtsc()
    hold m = espCrearModelo(s)
    when m == 0 {
        kprintln(cadena("enca=hablar: sin memoria para el modelo"))
        give false
    }
    kprint(cadena("modelo hablante creado: "))
    kprintEntero(s)
    kprint(cadena(" ranuras por orden, "))
    kprintEntero(mib(ncaBytesReservados()))
    kprint(cadena(" MiB reservados por ENCA en total, "))
    kprintEntero((rdtsc() - tc) / cpm)
    kprintln(cadena(" ms"))
    kprintln(cadena("entrenando (vigilia + 2 sueños por documento) ..."))
    hold bytes = espEntrenar(m)
    hold st = estadisticas()
    kprint(cadena("entrenamiento terminado: "))
    kprintEntero(bytes)
    kprint(cadena(" B en "))
    imprimirTiempo(leer64(st + 24) / cpm / 1000)
    kprint(cadena(" ("))
    kprintEntero(bytes * cpm * 1000 / leer64(st + 24))
    kprint(cadena(" B/s de corpus; vigilia "))
    kprintEntero(bytes * cpm * 1000 / leer64(st + 8))
    kprint(cadena(" B/s, sueño (2 pasadas) "))
    kprintEntero(bytes * 2 * cpm * 1000 / leer64(st + 16))
    kprintln(cadena(" B/s)"))
    hold mem = leer64(m + 8)
    kprint(cadena("hipocampo: sobrescrituras "))
    kprintEntero(leer64(mem + 80))
    kprint(cadena(", desalojos "))
    kprintEntero(leer64(mem + 88))
    kprint(cadena("; corteza: actualizaciones "))
    kprintEntero(leer64(leer64(m + 16) + 184))
    kprintByte(10)
    // Evaluaciones: la completa (por fuente) y, al final, la de las pruebas
    // congeladas A/B, que quedan en encaResultado(1) para la cabecera del estado.
    espEvaluarCompleto(m)
    hold te = rdtsc()
    hold bytesAB = espEvaluarSilencioso(m)
    hold ra = encaResultado(1)
    kprint(cadena("pruebas congeladas del hablante ("))
    kprintEntero(bytesAB)
    kprint(cadena(" B, "))
    kprintEntero((rdtsc() - te) / cpm)
    kprint(cadena(" ms): A mezcla "))
    kprintDecimal(lf(ra), 4)
    kprint(cadena(", B mezcla "))
    kprintDecimal(lf(ra + 32), 4)
    kprint(cadena(" bits/byte; top-1 A "))
    kprintEntero(leer64(ra + 24))
    kprint(cadena(", B "))
    kprintEntero(leer64(ra + 56))
    kprintln(cadena(" por mil"))
    // Registro (las ranuras de estado.l ya son las del hablante) y guardado.
    encaFijarRanurasEstado(s)
    encaFijarHablante(m, s, bytes)
    hold paso = espPasoSiguiente()
    hold guardado = espGuardarHablante(m, paso, true, bytes)
    encaFijarPerfil(previo)
    kprint(cadena("modelo hablante: tiempo total "))
    imprimirTiempo((rdtsc() - tInicio) / cpm / 1000)
    kprintByte(10)
    give guardado
}

// Carga el hablante de HABLA_A/B (la ranura válida más reciente). 0 = no hay
// ranuras (sin mensaje); 1 = cargado; 2 = hay ranuras pero algo falló. No
// cambia el perfil activo.
expose flow espCargarHablante() => Int {
    ifPunto(cadena("hab0"))
    when !discoHayPermitida() || !fatMontar() { give 0 }
    change cap = 0
    when fatAbrir(cadena("HABLA_A.BIN")) { cap = fatTamanoArchivo() }
    when fatAbrir(cadena("HABLA_B.BIN")) && fatTamanoArchivo() > cap { cap = fatTamanoArchivo() }
    when cap <= 512 { give 0 }
    cap = cap - 512
    ckptConfigurar(CKPT_HABLA, cap)
    hold buf = montonReservar(cap + 1024)
    when buf == 0 {
        kprintln(cadena("estado hablante: sin memoria para el búfer del estado"))
        give 2
    }
    ifPunto(cadena("habBuf"))
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    hold paso = ckptCargar(CKPT_HABLA, buf)
    hold t1 = rdtsc()
    ifPunto(cadena("habLeer"))
    when paso < 0 {
        kprintln(cadena("estado hablante: HABLA_A.BIN / HABLA_B.BIN sin ranura válida (cabecera o CRC32C); no se carga"))
        montonLiberar(buf)
        give 2
    }
    hold s = leer64(buf + 16)
    when s < 65536 || s > 4194304 || (s & (s - 1)) != 0 {
        kprintln(cadena("estado hablante: ranuras por orden inválidas en la cabecera; no se carga"))
        montonLiberar(buf)
        give 2
    }
    hold previo = encaPerfil()
    encaFijarRanurasEstado(s)
    when !encaCabeceraCompatible(buf) {
        kprintln(cadena("estado hablante: configuración distinta de la C5; no se carga"))
        encaFijarPerfil(previo)
        montonLiberar(buf)
        give 2
    }
    hold m = espCrearModelo(s)
    when m == 0 {
        kprintln(cadena("estado hablante: sin memoria para el modelo"))
        encaFijarPerfil(previo)
        montonLiberar(buf)
        give 2
    }
    ifPunto(cadena("habMod"))
    hold t2 = rdtsc()
    when !encaDeserializar(m, buf) {
        kprintln(cadena("estado hablante: no se pudo copiar el estado al modelo"))
        encaFijarPerfil(previo)
        montonLiberar(buf)
        give 2
    }
    hold t3 = rdtsc()
    ifPunto(cadena("habCopia"))
    hold total = leer64(buf + 96)
    kprint(cadena("modelo hablante cargado: ranura "))
    letra(ckptRanuraCargada(CKPT_HABLA))
    kprint(cadena(", paso "))
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
    kprintEntero(leer64(buf + 104))
    kprintln(cadena(" B de corpus entrenados"))
    encaFijarHablante(m, s, leer64(buf + 104))
    encaFijarPerfil(previo)
    // Comprobación barata de lo guardado: las pruebas congeladas (63 KB, ~1 s),
    // si está es/prueba.bin. No se repite la prueba completa (1 MB).
    hold rc = espCargarCorpus(true, false)
    when rc == 0 {
        hold te = rdtsc()
        espEvaluarSilencioso(m)
        ifPunto(cadena("habEval"))
        hold dif = encaCompararMetricas(buf)
        kprint(cadena("  evaluación de las pruebas congeladas en "))
        kprintEntero((rdtsc() - te) / cpm)
        when dif == 0 {
            kprintln(cadena(" ms: idéntica a la guardada en la cabecera"))
        } otherwise {
            kprint(cadena(" ms: DIFERENTE de la cabecera ("))
            kprintEntero(dif)
            kprintln(cadena(" métricas); ¡el estado cargado no coincide con el guardado!"))
        }
    } otherwise {
        kprintln(cadena("  sin es/prueba.bin: no se compara la evaluación (el CRC32C de la ranura sí se verificó); :guardar no podrá evaluar"))
    }
    montonLiberar(buf)
    ifPunto(cadena("habFin"))
    give 1
}
