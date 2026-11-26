// ENCA en el kernel: experimento exp009, configuración C5, reproducido bit a
// bit contra la referencia de Windows (enca_exp009_c5.l). El corpus se lee de
// la FAT32 (ELEDATOS) bajo enca/, se verifica tamaño y CRC32 y se ejecuta
// entrenamiento (vigilia + 2 sueños intercalados por archivo) y las pruebas
// A y B con autocompletado. Compara contra los números de Windows incrustados.

take nucleo.cpu
take nucleo.mem
take mem.monton
take lib.consola
take lib.crc32
take lib.matf64
take dispositivos.apic
take almacenamiento.disco
take almacenamiento.fat32
take enca.matematica
take enca.modelo
take enca.perfil
take enca.rapido
take cpu.buzon

fixed ARCHIVOS = 18
fixed ENTRENAMIENTO = 11
fixed PRUEBA_A = 16

// ---- tabla del corpus (ruta relativa a ENCA\, tamaño, CRC32) ------------------
flow corpusRuta(i: Int) => Int {
    when i == 0 { give cadena("enca/src/math/rng.l") }
    when i == 1 { give cadena("enca/src/math/math_utils.l") }
    when i == 2 { give cadena("enca/src/core/microcolumn.l") }
    when i == 3 { give cadena("enca/src/core/plasticity.l") }
    when i == 4 { give cadena("enca/src/memory/hippocampus.l") }
    when i == 5 { give cadena("enca/src/symbol/parser_utf8.l") }
    when i == 6 { give cadena("enca/experiments/enca_exp001_xor.l") }
    when i == 7 { give cadena("enca/experiments/enca_exp002_hipocampo.l") }
    when i == 8 { give cadena("enca/experiments/enca_exp003_continuo.l") }
    when i == 9 { give cadena("enca/experiments/enca_exp004_cognitivo.l") }
    when i == 10 { give cadena("enca/experiments/enca_exp005_escalas.l") }
    when i == 11 { give cadena("enca/experiments/enca_exp006_final.l") }
    when i == 12 { give cadena("enca/experiments/enca_exp007_lenguaje.l") }
    when i == 13 { give cadena("enca/tests/test_math.l") }
    when i == 14 { give cadena("enca/tests/test_core.l") }
    when i == 15 { give cadena("enca/tests/test_memory_symbol.l") }
    when i == 16 { give cadena("enca/src/memory/memoria_secuencial.l") }
    give cadena("enca/src/core/corteza_bytes.l")
}

flow corpusTam(i: Int) => Int {
    when i == 0 { give 1110 }
    when i == 1 { give 2744 }
    when i == 2 { give 4044 }
    when i == 3 { give 1637 }
    when i == 4 { give 2147 }
    when i == 5 { give 4409 }
    when i == 6 { give 18700 }
    when i == 7 { give 22481 }
    when i == 8 { give 29034 }
    when i == 9 { give 18835 }
    when i == 10 { give 19920 }
    when i == 11 { give 13309 }
    when i == 12 { give 15347 }
    when i == 13 { give 899 }
    when i == 14 { give 773 }
    when i == 15 { give 848 }
    when i == 16 { give 6428 }
    give 9353
}

flow corpusCrc(i: Int) => Int {
    when i == 0 { give 0x2AE43F83 }
    when i == 1 { give 0x47EA08A1 }
    when i == 2 { give 0x3043F965 }
    when i == 3 { give 0x0BB5D870 }
    when i == 4 { give 0x289715D9 }
    when i == 5 { give 0x77292B7D }
    when i == 6 { give 0x5B71077B }
    when i == 7 { give 0xF802A1CB }
    when i == 8 { give 0x57895625 }
    when i == 9 { give 0x91D93A52 }
    when i == 10 { give 0x0DE085C7 }
    when i == 11 { give 0x85E144A7 }
    when i == 12 { give 0x8D0994F6 }
    when i == 13 { give 0xEED0A3C4 }
    when i == 14 { give 0x95F60129 }
    when i == 15 { give 0x40181782 }
    when i == 16 { give 0xF6F435F4 }
    give 0xC7B19A9D
}

// Estado: +0 diferencias con la referencia, +8..+152 texto de cada archivo
// (dirección, 18 entradas).
flow tablaTextos() => Int { give reservar(160, 8) }
flow textoDe(i: Int) => Int { give leer64(tablaTextos() + 8 + i * 8) }

// Resultados de cada modo (0 exacto, 1 rápido), 192 bytes por modo, para que
// el hito 17 compare:
//  +0 mezcla A  +8 hipocampo A  +16 corteza A  +24 top-1 A (por mil)
//  +32 mezcla B +40 hipocampo B +48 corteza B  +56 top-1 B
//  +64 ciclos vigilia  +72 ciclos sueño  +80 bytes de entrenamiento
//  +88 ciclos de inferencia  +96 bytes de evaluación  +104 ciclos de autocompletado
//  +112 ciclos totales de la ejecución  +120 aciertos A  +128 aciertos B  +136 1 si hubo ejecución
flow resultados() => Int { give reservar(384, 8) }
expose flow encaResultado(modo: Int) => Int { give resultados() + modo * 192 }

// ---- impresión ----------------------------------------------------------------

// Float con 15 decimales y punto decimal (como en Windows).
flow imprimirF(x: Float) {
    hold buf = reservar(48, 8)
    hold n = fmtDecimal(x, 15, buf)
    each i among 0..n {
        hold b = leer8(buf + i)
        when b == 44 { kprintByte(46) } otherwise { kprintByte(b) }
    }
}

flow imprimirMs(ciclos: Int) {
    kprintEntero(ciclos / tscCiclosPorMs())
}

// m * 2^e con 2^52 <= m < 2^53 (imprimirExacto de la referencia).
flow exactoM(x: Float) => Int {
    change v = x
    when v > 0.0 {
        during v >= 9007199254740992.0 { v = v * 0.5 }
        during v < 4503599627370496.0 { v = v * 2.0 }
    }
    give Int(v)
}

flow exactoE(x: Float) => Int {
    change v = x
    change e = 0
    when v > 0.0 {
        during v >= 9007199254740992.0 {
            v = v * 0.5
            e += 1
        }
        during v < 4503599627370496.0 {
            v = v * 2.0
            e -= 1
        }
    }
    give e
}

flow imprimirExacto(nombre: Int, x: Float) {
    kprint(nombre)
    kprint(cadena(" "))
    kprintEntero(exactoM(x))
    kprint(cadena(" * 2^"))
    kprintEntero(exactoE(x))
}

flow porMil(parte: Int, total: Int) => Int {
    when total <= 0 { give 0 }
    give (parte * 1000) / total
}

// ---- comparación con Windows ---------------------------------------------------

flow comparar(nombre: Int, obtenido: Int, esperado: Int) {
    when obtenido != esperado {
        hold d = tablaTextos()
        escribir64(d, leer64(d) + 1)
        kprint(cadena("  diferencia en "))
        kprint(nombre)
        kprint(cadena(": kernel "))
        kprintEntero(obtenido)
        kprint(cadena(", Windows "))
        kprintEntero(esperado)
        kprintByte(10)
    }
}

// Escala a 15 decimales (para comparar con la impresión de Windows).
flow escala15(x: Float) => Int {
    give Int(x * 1000000000000000.0 + 0.5)
}

flow compararExacto(nombre: Int, x: Float, m: Int, e: Int) {
    comparar(nombre, exactoM(x), m)
    comparar(nombre, exactoE(x), e)
}

flow pesoEsperado(i: Int) => Int {
    when i == 0 { give 843308020692972 }
    when i == 1 { give 44899790296701 }
    when i == 2 { give 429631640392368 }
    when i == 3 { give 376215181489248 }
    when i == 4 { give 406895685704422 }
    when i == 5 { give 352600208485169 }
    when i == 6 { give 496165232450578 }
    when i == 7 { give 260468228974616 }
    when i == 8 { give 520467988668307 }
    when i == 9 { give 217751195002603 }
    when i == 10 { give 505489959779274 }
    give 134427162789503
}

// ---- informe de una prueba (A = 0, B = 1) ---------------------------------------
flow informar(m: Int, etiqueta: Int, prueba: Int, modo: Int) {
    change bytes = leer64(m + 80)
    when bytes < 1 { bytes = 1 }
    hold n = intToFloat(bytes)
    hold bm = lf(m + 88) / n
    hold bh = lf(m + 96) / n
    hold bc = lf(m + 104) / n
    hold top = porMil(leer64(m + 112), leer64(m + 80))
    hold acept = leer64(m + 144)
    hold resto = leer64(m + 136)
    hold res = encaResultado(modo) + prueba * 32
    ef(res, bm)
    ef(res + 8, bh)
    ef(res + 16, bc)
    escribir64(res + 24, top)
    escribir64(encaResultado(modo) + 120 + prueba * 8, leer64(m + 144))
    kprint(etiqueta)
    kprint(cadena(": bits/byte mezcla="))
    imprimirF(bm)
    kprint(cadena(" hipocampo="))
    imprimirF(bh)
    kprint(cadena(" corteza="))
    imprimirF(bc)
    kprint(cadena(" | top-1="))
    kprintEntero(top)
    kprintln(cadena(" por mil"))
    kprint(cadena("  exacto:"))
    imprimirExacto(cadena(" mezcla"), bm)
    imprimirExacto(cadena(", hipocampo"), bh)
    imprimirExacto(cadena(", corteza"), bc)
    kprintByte(10)
    kprint(cadena("  autocompletado: caracteres aceptados "))
    kprintEntero(acept)
    kprint(cadena("/"))
    kprintEntero(resto)
    kprint(cadena(" ("))
    kprintEntero(porMil(acept, resto))
    kprint(cadena(" por mil), líneas exactas "))
    kprintEntero(leer64(m + 128))
    kprint(cadena("/"))
    kprintEntero(leer64(m + 120))
    kprintByte(10)
    when modo == 1 { give }
    when prueba == 0 {
        compararExacto(cadena("A mezcla"), bm, 5886232681853270, -52)
        compararExacto(cadena("A hipocampo"), bh, 7119176556848176, -52)
        compararExacto(cadena("A corteza"), bc, 7063690614717264, -51)
        comparar(cadena("A top-1"), top, 811)
        comparar(cadena("A caracteres aceptados"), acept, 3446)
        comparar(cadena("A caracteres restantes"), resto, 22241)
        comparar(cadena("A lineas exactas"), leer64(m + 128), 5)
        comparar(cadena("A lineas"), leer64(m + 120), 658)
    } otherwise {
        compararExacto(cadena("B mezcla"), bm, 6231673534097902, -51)
        compararExacto(cadena("B hipocampo"), bh, 8900394946913047, -51)
        compararExacto(cadena("B corteza"), bc, 8954343722000678, -51)
        comparar(cadena("B top-1"), top, 637)
        comparar(cadena("B caracteres aceptados"), acept, 952)
        comparar(cadena("B caracteres restantes"), resto, 10492)
        comparar(cadena("B lineas exactas"), leer64(m + 128), 7)
        comparar(cadena("B lineas"), leer64(m + 120), 347)
    }
}

// ---- carga y verificación del corpus --------------------------------------------
// 0 = verificado, 1 = corpus ausente (omitir), 2 = corpus incorrecto (fallo).
flow cargarCorpus() => Int {
    when !discoHayPermitida() {
        kprintln(cadena("corpus ENCA no encontrado: no hay partición ELEDATOS"))
        give 1
    }
    when !fatMontar() {
        kprintln(cadena("corpus ENCA no encontrado: la partición no es FAT32"))
        give 1
    }
    hold tabla = tablaTextos()
    change bien = true
    each i among 0..ARCHIVOS {
        hold ruta = corpusRuta(i)
        when !fatAbrir(ruta) {
            kprint(cadena("corpus ENCA no encontrado: falta "))
            kprintln(ruta)
            when i == 0 { give 1 }
            give 2
        }
        hold tam = fatTamanoArchivo()
        hold buf = ncaReservar(tam + 1024)
        when buf == 0 {
            kprintln(cadena("corpus ENCA: sin memoria para el corpus"))
            give 2
        }
        hold leidos = fatLeer(0, tam, buf)
        hold crc = crc32(buf, leidos)
        when tam != corpusTam(i) || leidos != tam || crc != corpusCrc(i) {
            kprint(cadena("corpus ENCA INCORRECTO: "))
            kprint(ruta)
            kprint(cadena(" tamaño "))
            kprintEntero(tam)
            kprint(cadena(" (esperado "))
            kprintEntero(corpusTam(i))
            kprint(cadena("), CRC32 "))
            kprintHex(crc)
            kprint(cadena(" (esperado "))
            kprintHex(corpusCrc(i))
            kprintln(cadena(")"))
            bien = false
        }
        escribir64(tabla + 8 + i * 8, buf)
    }
    when !bien { give 2 }
    give 0
}

// ---- ejecución ---------------------------------------------------------------------
// Devuelve 1 si reproduce Windows, 0 si no, 2 si el corpus no está.
// modo 0 = exacto (compara con Windows); 1 = rápido (solo informa). El corpus
// se carga y verifica una sola vez (la segunda ejecución lo reutiliza).
expose flow encaEjecutar(modo: Int) => Int {
    when modo == 0 {
        kprintln(cadena("ENCA exp009 C5: hipocampo de 65536 ranuras por orden, mezcla geométrica, sueño intercalado x2"))
    } otherwise {
        kprintln(cadena("ENCA exp009 C5 en modo rápido (f32 + SSE + núcleo 1 en la corteza), mismo corpus"))
    }
    when leer64(tablaTextos() + 152) == 0 {
        hold estadoCorpus = cargarCorpus()
        when estadoCorpus == 1 { give 2 }
        when estadoCorpus == 2 { give 0 }
        escribir64(tablaTextos() + 152, 1)
        kprintln(cadena("corpus ENCA verificado (18 archivos: tamaño y CRC32)"))
    }
    hold cpm = tscCiclosPorMs()
    hold tInicio = rdtsc()

    perfilReiniciar()
    hold m = modeloCrear(65536, modo)
    when m == 0 {
        kprintln(cadena("ENCA: sin memoria para el modelo"))
        give 0
    }
    kprint(cadena("RAM reservada por ENCA: "))
    kprintEntero(ncaBytesReservados())
    kprint(cadena(" B ("))
    kprintEntero(ncaBytesReservados() / 1048576)
    kprintln(cadena(" MiB, con corpus)"))

    // Entrenamiento: vigilia + 2 sueños intercalados por archivo.
    change cVigilia = 0
    change cSueno = 0
    change bytesEntrenamiento = 0
    each i among 0..ENTRENAMIENTO {
        hold ruta = corpusRuta(i)
        hold tam = corpusTam(i)
        hold t0 = rdtsc()
        modeloVigilia(m, textoDe(i), tam)
        hold t1 = rdtsc()
        modeloSueno(m, textoDe(i), tam)
        modeloSueno(m, textoDe(i), tam)
        hold t2 = rdtsc()
        cVigilia += t1 - t0
        cSueno += t2 - t1
        bytesEntrenamiento += tam
        kprint(cadena("entrenando "))
        kprintEntero(i + 1)
        kprint(cadena("/11 "))
        kprint(ruta)
        kprint(cadena(" "))
        kprintEntero(tam)
        kprint(cadena(" B: vigilia "))
        imprimirMs(t1 - t0)
        kprint(cadena(" ms, sueño "))
        imprimirMs(t2 - t1)
        kprintln(cadena(" ms"))
    }

    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold mez = leer64(m + 24)
    hold actualizaciones = leer64(cor + 184)
    kprint(cadena("corteza: actualizaciones="))
    kprintEntero(actualizaciones)
    kprint(cadena(" (vigilia cerradas="))
    kprintEntero(leer64(m + 64))
    kprint(cadena(", consolidaciones en sueño="))
    kprintEntero(leer64(m + 72))
    kprint(cadena(") | hipocampo: sobrescrituras="))
    kprintEntero(leer64(mem + 80))
    kprint(cadena(" memoria="))
    kprintEntero(memBytesReservados(mem))
    kprintln(cadena(" B"))
    kprint(cadena("pesos geométricos por orden 0..5:"))
    hold pesos = leer64(mez + 32)
    each o among 0..6 {
        kprint(cadena(" ["))
        imprimirF(lf(pesos + o * 16))
        kprint(cadena(", "))
        imprimirF(lf(pesos + o * 16 + 8))
        kprint(cadena("]"))
    }
    kprintByte(10)
    when modo == 0 {
        comparar(cadena("actualizaciones"), actualizaciones, 180397)
        comparar(cadena("vigilia cerradas"), leer64(m + 64), 92407)
        comparar(cadena("consolidaciones"), leer64(m + 72), 147743)
        comparar(cadena("sobrescrituras"), leer64(mem + 80), 10799)
        comparar(cadena("memoria hipocampo"), memBytesReservados(mem), 70782976)
        each i among 0..12 { comparar(cadena("peso geometrico"), escala15(lf(pesos + i * 8)), pesoEsperado(i)) }
    }

    // Pruebas A y B.
    hold tE0 = rdtsc()
    metricasReiniciar(m)
    escribir64(m + 208, 0)
    change bytesA = 0
    each i among ENTRENAMIENTO..PRUEBA_A {
        kprint(cadena("evaluando "))
        kprint(corpusRuta(i))
        kprint(cadena(" "))
        kprintEntero(corpusTam(i))
        kprintln(cadena(" B ..."))
        modeloEvaluar(m, textoDe(i), corpusTam(i))
        bytesA += corpusTam(i)
    }
    informar(m, cadena("PRUEBA A (dominio ENCA)"), 0, modo)
    hold ciclosAutoA = leer64(m + 208)
    hold tE1 = rdtsc()

    metricasReiniciar(m)
    escribir64(m + 208, 0)
    change bytesB = 0
    each i among PRUEBA_A..ARCHIVOS {
        kprint(cadena("evaluando "))
        kprint(corpusRuta(i))
        kprint(cadena(" "))
        kprintEntero(corpusTam(i))
        kprintln(cadena(" B ..."))
        modeloEvaluar(m, textoDe(i), corpusTam(i))
        bytesB += corpusTam(i)
    }
    informar(m, cadena("PRUEBA B (código nuevo de la Fase 8)"), 1, modo)
    hold ciclosAutoB = leer64(m + 208)
    hold tE2 = rdtsc()
    hold tFin = rdtsc()

    // Medidas.
    hold cEval = (tE1 - tE0) + (tE2 - tE1)
    hold cAuto = ciclosAutoA + ciclosAutoB
    hold bytesEval = bytesA + bytesB
    hold cInferencia = cEval - cAuto
    kprintln(cadena("---- medidas ----"))
    kprint(cadena("entrenamiento: "))
    kprintEntero(bytesEntrenamiento)
    kprint(cadena(" B; vigilia "))
    imprimirMs(cVigilia)
    kprint(cadena(" ms = "))
    kprintEntero(bytesEntrenamiento * cpm * 1000 / cVigilia)
    kprint(cadena(" B/s; sueño (2 pasadas) "))
    imprimirMs(cSueno)
    kprint(cadena(" ms = "))
    kprintEntero(bytesEntrenamiento * 2 * cpm * 1000 / cSueno)
    kprint(cadena(" B/s; total "))
    imprimirMs(cVigilia + cSueno)
    kprint(cadena(" ms = "))
    kprintEntero(bytesEntrenamiento * cpm * 1000 / (cVigilia + cSueno))
    kprintln(cadena(" B/s de corpus"))
    kprint(cadena("inferencia (evaluación sin autocompletado): "))
    kprintEntero(bytesEval)
    kprint(cadena(" B en "))
    imprimirMs(cInferencia)
    kprint(cadena(" ms = "))
    kprintEntero(bytesEval * cpm * 1000 / cInferencia)
    kprint(cadena(" B/s; autocompletado "))
    imprimirMs(cAuto)
    kprintln(cadena(" ms"))
    perfilImprimir(0, cadena("vigilia"), cVigilia)
    perfilImprimir(1, cadena("sueño"), cSueno)
    perfilImprimir(2, cadena("evaluación"), cInferencia)
    perfilImprimir(3, cadena("autocompletado"), cAuto)
    kprint(cadena("RAM reservada por ENCA: "))
    kprintEntero(ncaBytesReservados())
    kprint(cadena(" B ("))
    kprintEntero(ncaBytesReservados() / 1048576)
    kprint(cadena(" MiB); tiempo total ENCA "))
    kprintEntero((tFin - tInicio) / cpm / 1000)
    kprintln(cadena(" s"))

    hold r = encaResultado(modo)
    escribir64(r + 64, cVigilia)
    escribir64(r + 72, cSueno)
    escribir64(r + 80, bytesEntrenamiento)
    escribir64(r + 88, cInferencia)
    escribir64(r + 96, bytesEval)
    escribir64(r + 104, cAuto)
    escribir64(r + 112, tFin - tInicio)
    escribir64(r + 136, 1)
    when modo == 1 {
        kprintln(cadena("ENCA C5 rápido: terminado"))
        give 1
    }
    // El hipocampo exacto (70 MB) ya no hace falta: se devuelve al montón.
    memLiberar(mem)
    when leer64(tablaTextos()) == 0 {
        kprintln(cadena("ENCA C5: idéntico a Windows"))
        give 1
    }
    kprint(cadena("ENCA C5: DIFERENTE de Windows ("))
    kprintEntero(leer64(tablaTextos()))
    kprintln(cadena(" diferencias)"))
    give 0
}

// ---- hito 17: modo rápido frente al exacto ------------------------------------

flow velocidad(bytes: Int, ciclos: Int) => Int {
    when ciclos < 1 { give 0 }
    give bytes * tscCiclosPorMs() * 1000 / ciclos
}

// veces * 100 = a / b.
flow veces100(a: Int, b: Int) => Int {
    when b < 1 { give 0 }
    give a * 100 / b
}

flow imprimirVeces(v100: Int) {
    kprintEntero(v100 / 100)
    kprintByte(46)
    when v100 % 100 < 10 { kprintByte(48) }
    kprintEntero(v100 % 100)
    kprint(cadena("x"))
}

flow filaVelocidad(nombre: Int, exacto: Int, rapido: Int) {
    kprint(cadena("  "))
    kprint(nombre)
    kprint(cadena(" exacto "))
    kprintEntero(exacto)
    kprint(cadena(" B/s, rápido "))
    kprintEntero(rapido)
    kprint(cadena(" B/s, aceleración "))
    imprimirVeces(veces100(rapido, exacto))
    kprintByte(10)
}

// 1 = hito 17 correcto, 0 = falló, 2 = omitido (sin corpus / sin ejecución exacta).
expose flow encaHito17() => Int {
    hold ex = encaResultado(0)
    when leer64(ex + 136) == 0 { give 2 }
    kprint(cadena("ENCA rápido: núcleos en línea (BSP incluido): "))
    kprintEntero(buzonNucleos())
    kprintByte(10)
    hold vlnOk = vlnMedir(1048576)
    hold r = encaEjecutar(1)
    when r != 1 { give 0 }
    hold ra = encaResultado(1)
    hold dA = lf(ra) - lf(ex)
    hold dB = lf(ra + 32) - lf(ex + 32)
    kprintln(cadena("---- rápido frente a exacto ----"))
    kprint(cadena("delta bits/byte (rápido - exacto) PRUEBA A: mezcla "))
    imprimirF(dA)
    kprint(cadena(" hipocampo "))
    imprimirF(lf(ra + 8) - lf(ex + 8))
    kprint(cadena(" corteza "))
    imprimirF(lf(ra + 16) - lf(ex + 16))
    kprintByte(10)
    kprint(cadena("delta bits/byte (rápido - exacto) PRUEBA B: mezcla "))
    imprimirF(dB)
    kprint(cadena(" hipocampo "))
    imprimirF(lf(ra + 40) - lf(ex + 40))
    kprint(cadena(" corteza "))
    imprimirF(lf(ra + 48) - lf(ex + 48))
    kprintByte(10)
    kprint(cadena("top-1 (por mil) A: exacto "))
    kprintEntero(leer64(ex + 24))
    kprint(cadena(", rápido "))
    kprintEntero(leer64(ra + 24))
    kprint(cadena("; B: exacto "))
    kprintEntero(leer64(ex + 56))
    kprint(cadena(", rápido "))
    kprintEntero(leer64(ra + 56))
    kprintByte(10)
    kprint(cadena("autocompletado, caracteres aceptados A: exacto "))
    kprintEntero(leer64(ex + 120))
    kprint(cadena(", rápido "))
    kprintEntero(leer64(ra + 120))
    kprint(cadena("; B: exacto "))
    kprintEntero(leer64(ex + 128))
    kprint(cadena(", rápido "))
    kprintEntero(leer64(ra + 128))
    kprintByte(10)
    hold bytesE = leer64(ex + 80)
    hold bytesV = leer64(ex + 96)
    hold vigE = velocidad(bytesE, leer64(ex + 64))
    hold vigR = velocidad(bytesE, leer64(ra + 64))
    hold sueE = velocidad(bytesE * 2, leer64(ex + 72))
    hold sueR = velocidad(bytesE * 2, leer64(ra + 72))
    hold entE = velocidad(bytesE, leer64(ex + 64) + leer64(ex + 72))
    hold entR = velocidad(bytesE, leer64(ra + 64) + leer64(ra + 72))
    hold infE = velocidad(bytesV, leer64(ex + 88))
    hold infR = velocidad(bytesV, leer64(ra + 88))
    kprintln(cadena("velocidad (bytes de corpus por segundo):"))
    filaVelocidad(cadena("vigilia      "), vigE, vigR)
    filaVelocidad(cadena("sueño        "), sueE, sueR)
    filaVelocidad(cadena("entrenamiento"), entE, entR)
    filaVelocidad(cadena("inferencia   "), infE, infR)
    hold tE = leer64(ex + 112)
    hold tR = leer64(ra + 112)
    kprint(cadena("  tiempo total ENCA: exacto "))
    kprintEntero(tE / tscCiclosPorMs())
    kprint(cadena(" ms, rápido "))
    kprintEntero(tR / tscCiclosPorMs())
    kprint(cadena(" ms, aceleración "))
    imprimirVeces(veces100(tE, tR))
    kprintByte(10)
    hold limite = 0.001
    hold bien = absF(dA) < limite && absF(dB) < limite && tR < tE && vlnOk
    when bien { give 1 }
    kprintln(cadena("hito 17: criterio no cumplido (|delta| < 0,001 en A y B, rápido más veloz que exacto, vln dentro de tolerancia)"))
    give 0
}
