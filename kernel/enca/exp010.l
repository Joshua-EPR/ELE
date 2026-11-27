// ENCA en el kernel: experimento exp010, mejor configuración (C5, orden O0),
// reproducido en modo EXACTO contra los valores de Windows
// (ENCA\experiments\enca_exp010.l). Se ejecuta solo con la opción de arranque
// enca=exp010 (hito 20).
//
// Pruebas A y B de dos formas:
//   - congelada (como exp009, con autocompletado): sobre el modelo entrenado;
//   - precuencial: byte a byte predice, mide y aprende con el paso de vigilia
//     (modeloPrecuencial). A y B parten cada una del estado al terminar el
//     entrenamiento: tras la A (que lo modifica) se REENTRENA (determinista)
//     para la B, igual que en la referencia de Windows.
// C6 (recalibrar el mezclador tras el sueño) resultó peor que C5 en Windows
// (ver bitácora), así que el kernel solo porta C5 + precuencial.

take nucleo.cpu
take nucleo.mem
take mem.monton
take lib.consola
take dispositivos.apic
take enca.matematica
take enca.modelo
take enca.perfil
take enca.exp009

fixed ENTRENAMIENTO = 11
fixed PRUEBA_A = 16
fixed ARCHIVOS = 18

// +0 número de diferencias con Windows.
flow estado() => Int { give reservar(16, 8) }

flow comparar(nombre: Int, obtenido: Int, esperado: Int) {
    when obtenido != esperado {
        escribir64(estado(), leer64(estado()) + 1)
        kprint(cadena("  diferencia en "))
        kprint(nombre)
        kprint(cadena(": kernel "))
        kprintEntero(obtenido)
        kprint(cadena(", Windows "))
        kprintEntero(esperado)
        kprintByte(10)
    }
}

flow compararExacto(nombre: Int, x: Float, m: Int, e: Int) {
    comparar(nombre, encaExactoM(x), m)
    comparar(nombre, encaExactoE(x), e)
}

// Valores de Windows (C5, orden O0). k: 0 A congelada, 1 B congelada,
// 2 A precuencial, 3 B precuencial. campo:
//   0 mezcla (mantisa) 1 mezcla (exponente) 2 hipocampo m 3 hipocampo e
//   4 corteza m 5 corteza e 6 top-1 por mil 7 aceptados 8 restantes
//   9 líneas exactas 10 líneas
flow esperado(k: Int, campo: Int) => Int {
    when k == 0 {
        when campo == 0 { give 5886232681853270 }
        when campo == 1 { give -52 }
        when campo == 2 { give 7119176556848176 }
        when campo == 3 { give -52 }
        when campo == 4 { give 7063690614717264 }
        when campo == 5 { give -51 }
        when campo == 6 { give 811 }
        when campo == 7 { give 3446 }
        when campo == 8 { give 22241 }
        when campo == 9 { give 5 }
        give 658
    }
    when k == 1 {
        when campo == 0 { give 6231673534097902 }
        when campo == 1 { give -51 }
        when campo == 2 { give 8900394946913047 }
        when campo == 3 { give -51 }
        when campo == 4 { give 8954343722000678 }
        when campo == 5 { give -51 }
        when campo == 6 { give 637 }
        when campo == 7 { give 952 }
        when campo == 8 { give 10492 }
        when campo == 9 { give 7 }
        give 347
    }
    when k == 2 {
        when campo == 0 { give 8798484689747517 }
        when campo == 1 { give -53 }
        when campo == 2 { give 5290898831439956 }
        when campo == 3 { give -52 }
        when campo == 4 { give 5921472139329804 }
        when campo == 5 { give -51 }
        give 841
    }
    when campo == 0 { give 7575402504172646 }
    when campo == 1 { give -52 }
    when campo == 2 { give 4904248011750882 }
    when campo == 3 { give -51 }
    when campo == 4 { give 7170383581864550 }
    when campo == 5 { give -51 }
    give 740
}

flow nombrePrueba(k: Int) => Int {
    when k == 0 { give cadena("A congelada  ") }
    when k == 1 { give cadena("B congelada  ") }
    when k == 2 { give cadena("A precuencial") }
    give cadena("B precuencial")
}

flow imprimirExacto(nombre: Int, x: Float) {
    kprint(nombre)
    kprint(cadena(" "))
    kprintEntero(encaExactoM(x))
    kprint(cadena(" * 2^"))
    kprintEntero(encaExactoE(x))
}

// Resultados de las 4 evaluaciones (para la tabla final): 4 x 32 bytes con
// +0 mezcla +8 hipocampo +16 corteza (bits de Float) +24 top-1.
flow resultados() => Int { give reservar(128, 8) }

// Evalúa la prueba (0 = A, 1 = B) en el modo 0 congelada / 1 precuencial,
// la imprime y la compara con Windows. Devuelve los bytes evaluados.
flow evaluarPrueba(m: Int, prueba: Int, modo: Int) => Int {
    hold k = modo * 2 + prueba
    metricasReiniciar(m)
    escribir64(m + 208, 0)
    change inicio = ENTRENAMIENTO
    change fin = PRUEBA_A
    when prueba == 1 {
        inicio = PRUEBA_A
        fin = ARCHIVOS
    }
    change bytes = 0
    each i among inicio..fin {
        when modo == 0 {
            modeloEvaluar(m, encaTextoDe(i), encaTamDe(i))
        } otherwise {
            modeloPrecuencial(m, encaTextoDe(i), encaTamDe(i))
        }
        bytes += encaTamDe(i)
    }
    change nb = leer64(m + 80)
    when nb < 1 { nb = 1 }
    hold n = intToFloat(nb)
    hold bm = lf(m + 88) / n
    hold bh = lf(m + 96) / n
    hold bc = lf(m + 104) / n
    hold top = encaPorMil(leer64(m + 112), leer64(m + 80))
    hold r = resultados() + k * 32
    ef(r, bm)
    ef(r + 8, bh)
    ef(r + 16, bc)
    escribir64(r + 24, top)
    kprint(cadena("PRUEBA "))
    kprint(nombrePrueba(k))
    kprint(cadena(": bits/byte mezcla="))
    encaImprimirF(bm)
    kprint(cadena(" hipocampo="))
    encaImprimirF(bh)
    kprint(cadena(" corteza="))
    encaImprimirF(bc)
    kprint(cadena(" | top-1="))
    kprintEntero(top)
    kprintln(cadena(" por mil"))
    kprint(cadena("  exacto:"))
    imprimirExacto(cadena(" mezcla"), bm)
    imprimirExacto(cadena(", hipocampo"), bh)
    imprimirExacto(cadena(", corteza"), bc)
    kprintByte(10)
    when modo == 0 {
        kprint(cadena("  autocompletado: caracteres aceptados "))
        kprintEntero(leer64(m + 144))
        kprint(cadena("/"))
        kprintEntero(leer64(m + 136))
        kprint(cadena(", líneas exactas "))
        kprintEntero(leer64(m + 128))
        kprint(cadena("/"))
        kprintEntero(leer64(m + 120))
        kprintByte(10)
    }
    compararExacto(cadena("mezcla"), bm, esperado(k, 0), esperado(k, 1))
    compararExacto(cadena("hipocampo"), bh, esperado(k, 2), esperado(k, 3))
    compararExacto(cadena("corteza"), bc, esperado(k, 4), esperado(k, 5))
    comparar(cadena("top-1"), top, esperado(k, 6))
    when modo == 0 {
        comparar(cadena("caracteres aceptados"), leer64(m + 144), esperado(k, 7))
        comparar(cadena("caracteres restantes"), leer64(m + 136), esperado(k, 8))
        comparar(cadena("lineas exactas"), leer64(m + 128), esperado(k, 9))
        comparar(cadena("lineas"), leer64(m + 120), esperado(k, 10))
    }
    give bytes
}

// Entrena C5 con el orden O0: vigilia + 2 sueños intercalados por archivo.
// Devuelve los bytes de corpus entrenados.
flow entrenar(m: Int) => Int {
    change bytes = 0
    each i among 0..ENTRENAMIENTO {
        modeloVigilia(m, encaTextoDe(i), encaTamDe(i))
        modeloSueno(m, encaTextoDe(i), encaTamDe(i))
        modeloSueno(m, encaTextoDe(i), encaTamDe(i))
        bytes += encaTamDe(i)
    }
    give bytes
}

// 1 = idéntico a Windows, 0 = hay diferencias, 2 = sin corpus verificado.
expose flow encaExp010() => Int {
    when !encaCorpusListo() { give 2 }
    escribir64(estado(), 0)
    kprintln(cadena("ENCA exp010 (C5, orden O0, modo exacto): congelada y precuencial en A y B"))
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()

    // Entrenamiento 1: pruebas congeladas y A precuencial.
    perfilReiniciar()
    hold m = modeloCrear(65536, 0)
    when m == 0 {
        kprintln(cadena("ENCA: sin memoria para el modelo"))
        give 0
    }
    hold bytesEntrenados = entrenar(m)
    hold t1 = rdtsc()
    kprint(cadena("entrenamiento 1: "))
    kprintEntero(bytesEntrenados)
    kprint(cadena(" B de corpus en "))
    encaImprimirMs(t1 - t0)
    kprintln(cadena(" ms"))
    change bytesEval = evaluarPrueba(m, 0, 0)
    bytesEval += evaluarPrueba(m, 1, 0)
    hold t2 = rdtsc()
    bytesEval += evaluarPrueba(m, 0, 1)
    hold t3 = rdtsc()
    memLiberar(leer64(m + 8))

    // Entrenamiento 2: B precuencial desde el estado recién entrenado.
    hold m2 = modeloCrear(65536, 0)
    when m2 == 0 {
        kprintln(cadena("ENCA: sin memoria para el modelo (2)"))
        give 0
    }
    entrenar(m2)
    hold t4 = rdtsc()
    kprint(cadena("entrenamiento 2 (reentrenado para B precuencial): "))
    encaImprimirMs(t4 - t3)
    kprintln(cadena(" ms"))
    bytesEval += evaluarPrueba(m2, 1, 1)
    hold t5 = rdtsc()
    memLiberar(leer64(m2 + 8))

    // Resumen.
    hold r = resultados()
    kprintln(cadena("---- exp010 en el kernel (C5, O0) ----"))
    each k among 0..4 {
        kprint(cadena("  "))
        kprint(nombrePrueba(k))
        kprint(cadena(": bits/byte mezcla "))
        encaImprimirF(lf(r + k * 32))
        kprint(cadena(", top-1 "))
        kprintEntero(leer64(r + k * 32 + 24))
        kprintln(cadena(" por mil"))
    }
    hold total = t5 - t0
    hold bytesTotal = 2 * bytesEntrenados * 3 + bytesEval
    kprint(cadena("tiempo total exp010: "))
    encaImprimirMs(total)
    kprint(cadena(" ms; bytes procesados (entrenamiento 2 x 11 archivos x 3 pasadas + evaluación): "))
    kprintEntero(bytesTotal)
    kprint(cadena(" = "))
    kprintEntero(bytesTotal * cpm * 1000 / total)
    kprintln(cadena(" B/s"))
    when leer64(estado()) == 0 {
        kprintln(cadena("exp010 C5: idéntico a Windows"))
        give 1
    }
    kprint(cadena("exp010 C5: DIFERENTE de Windows ("))
    kprintEntero(leer64(estado()))
    kprintln(cadena(" diferencias)"))
    give 0
}
