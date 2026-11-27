// ENCA: ModeloLenguajeBytes de exp009 en la configuración C5 (mezcla
// geométrica; sin la rama lineal/compuerta talámica de C0, que C5 no ejecuta).
// Vigilia (paso), sueño (pasoReplay), autocompletado con instantáneas y
// métricas, portados literalmente de enca_exp009_c5.l.
//
// Bloque del modelo (224 bytes; Float con los bits IEEE):
//   +0 ventana  +8 memoria  +16 corteza  +24 mezclador   (punteros a bloques)
//   +32 mezcla(F, 256)  +40 contextoMezcla  +48 umbralSorpresa(F)  +56 tasaCorteza(F)
//   +64 compuertasCerradas  +72 consolidaciones
//   Métricas: +80 bytes  +88 bitsMezcla(F)  +96 bitsMemoria(F)  +104 bitsCorteza(F)
//   +112 aciertosTop1  +120 lineas  +128 lineasExactas
//   +136 caracteresRestantes  +144 caracteresAcertados
//   +152 hashes[5] (Int, contextos de orden 1,2,3,4,6)   +192 iniciales[2] (F)
//   +208 ciclos de TSC gastados en el autocompletado (solo medida)
//   +216 modo: 0 exacto (f64, bit a bit con Windows), 1 rápido (f32 + SSE + 2 núcleos)

take nucleo.cpu
take nucleo.mem
take enca.matematica
take enca.ventana
take enca.memoria_secuencial
take enca.corteza_bytes
take enca.mezclador_geometrico
take enca.perfil
take enca.rapido

flow sorpresaBits(p: Float) => Float {
    give 0.0 - lnRapido(maxFloat(p, 0.000000001)) * 1.4426950408889634
}

expose flow modeloCrear(slots: Int, modo: Int) => Int {
    hold m = ncaReservar(224)
    hold mezcla = ncaReservar(256 * 8)
    when m == 0 || mezcla == 0 { give 0 }
    each j among 0..28 { escribir64(m + j * 8, 0) }
    each c among 0..256 { ef(mezcla + c * 8, 0.00390625) }
    escribir64(m + 216, modo)
    ef(m + 192, 1.0)
    ef(m + 200, 0.2)
    escribir64(m, ventanaCrear(8))
    escribir64(m + 8, memCrear(5, slots, 12, modo))
    escribir64(m + 16, cortezaCrear(512, 16, 2026, modo))
    escribir64(m + 24, mezCrear(6, 2, 0.003, m + 192, modo))
    when leer64(m) == 0 || leer64(m + 8) == 0 || leer64(m + 16) == 0 || leer64(m + 24) == 0 { give 0 }
    escribir64(m + 32, mezcla)
    ef(m + 48, 1.0)
    ef(m + 56, 0.02)
    give m
}

expose flow metricasReiniciar(m: Int) {
    escribir64(m + 80, 0)
    ef(m + 88, 0.0)
    ef(m + 96, 0.0)
    ef(m + 104, 0.0)
    escribir64(m + 112, 0)
    escribir64(m + 120, 0)
    escribir64(m + 128, 0)
    escribir64(m + 136, 0)
    escribir64(m + 144, 0)
}

expose flow modeloIniciarDocumento(m: Int) {
    ventanaReiniciar(leer64(m))
    cortezaReiniciar(leer64(m + 16))
    cortezaAvanzar(leer64(m + 16), 256, 256, 256, false)
}

// Calcula los hashes de contexto de la ventana actual en +152.
flow calcularHashes(m: Int) {
    hold v = leer64(m)
    escribir64(m + 152, ventanaHash(v, 1))
    escribir64(m + 160, ventanaHash(v, 2))
    escribir64(m + 168, ventanaHash(v, 3))
    escribir64(m + 176, ventanaHash(v, 4))
    escribir64(m + 184, ventanaHash(v, 6))
}

// Variante del aprendizaje de lo tecleado (hito 21). 0 hipocampo + corteza +
// mezclador; 1 sin mezclador; 2 solo hipocampo; 3 mezclador con tasa / 10.
// El entrenamiento la deja en 0; solo enca/aprender.l la cambia mientras
// aprende una línea.
flow variante() => Int { give reservar(8, 8) }
expose flow modeloFijarVariante(v: Int) { escribir64(variante(), v) }

flow modoRapido(m: Int) => Bool { give leer64(m + 216) == 1 }

// Predicción rápida del paso (los hashes ya están en +152 y los activos de
// lectura copiados): hipocampo en f32, lectura de la corteza, mezcla.
flow predecirRapido(m: Int) {
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold mez = leer64(m + 24)
    hold t1 = perfilIni()
    memPredecirRapido(mem, m + 152, leer64(mez + 56))
    perfilFin(PF_HIP_PRED, t1)
    hold t2 = perfilIni()
    cortezaPredecirRapido(cor)
    perfilFin(PF_COR_LECTURA, t2)
    hold t3 = perfilIni()
    escribir64(m + 40, leer64(mem + 72))
    mezCargarLogitsRapido(mez, leer64(cor + 208), lf(cor + 152))
    mezMezclarRapido(mez, leer64(m + 40))
    perfilFin(PF_MEZ_PRED, t3)
}

expose flow modeloPredecirMezcla(m: Int) => Int {
    when modoRapido(m) {
        hold t0 = perfilIni()
        calcularHashes(m)
        perfilFin(PF_VENTANA, t0)
        cortezaLeerActivosRapido(leer64(m + 16))
        predecirRapido(m)
        give mezMejorRapido(leer64(m + 24))
    }
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold mez = leer64(m + 24)
    hold t0 = perfilIni()
    calcularHashes(m)
    perfilFin(PF_VENTANA, t0)
    hold t1 = perfilIni()
    memPredecir(mem, m + 152)
    perfilFin(PF_HIP_PRED, t1)
    hold t2 = perfilIni()
    cortezaPredecir(cor)
    perfilFin(PF_COR_LECTURA, t2)
    hold t3 = perfilIni()
    escribir64(m + 40, leer64(mem + 72))
    mezCargarProbabilidades(mez, 0, mem + 2144)
    mezCargarLogits(mez, 1, leer64(cor + 112), lf(cor + 152))
    hold mejor = mezMezclar(mez, leer64(m + 40))
    hold mezcla = leer64(m + 32)
    hold distMez = leer64(mez + 48)
    each c among 0..256 { escribir64(mezcla + c * 8, leer64(distMez + c * 8)) }
    perfilFin(PF_MEZ_PRED, t3)
    give mejor
}

expose flow condicionar(m: Int, byte: Int) {
    hold v = leer64(m)
    hold t0 = perfilIni()
    ventanaEmpujar(v, byte)
    cortezaAvanzar(leer64(m + 16), ventanaAtras(v, 1), ventanaAtras(v, 2), ventanaAtras(v, 3), false)
    perfilFin(PF_COR_AVANZAR, t0)
}

// Vigilia: predecir, medir, aprender (hipocampo siempre; corteza con
// compuerta sobre la sorpresa de la mezcla; mezclador), avanzar.
// Paso rápido: igual que el exacto, pero el núcleo 1 avanza la corteza
// (sinapsis + k-WTA) mientras el 0 predice y aprende con los activos de
// lectura. Ver enca/rapido.l.
flow modeloPasoRapido(m: Int, byte: Int, aprender: Bool) {
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold mez = leer64(m + 24)
    hold v = leer64(m)
    perfilPaso()
    hold t0 = perfilIni()
    cortezaLeerActivosRapido(cor)
    calcularHashes(m)
    ventanaEmpujar(v, byte)
    hold b1 = ventanaAtras(v, 1)
    hold b2 = ventanaAtras(v, 2)
    hold b3 = ventanaAtras(v, 3)
    perfilFin(PF_VENTANA, t0)
    encaIniciarAvance(cor, b1, b2, b3, aprender)
    predecirRapido(m)
    hold tm = perfilIni()
    hold pMemoria = leerF32(leer64(mem + 4200) + byte * 4)
    hold pCorteza = leerF32(leer64(cor + 216) + byte * 4)
    hold sorpresa = sorpresaBits(leerF32(leer64(mez + 80) + byte * 4))
    escribir64(m + 80, leer64(m + 80) + 1)
    ef(m + 88, lf(m + 88) + sorpresa)
    ef(m + 96, lf(m + 96) + sorpresaBits(pMemoria))
    ef(m + 104, lf(m + 104) + sorpresaBits(pCorteza))
    when leerF32(leer64(mez + 72) + byte * 4) >= lf(mez + 88) { escribir64(m + 112, leer64(m + 112) + 1) }
    perfilFin(PF_METRICAS, tm)
    when aprender {
        hold t1 = perfilIni()
        memAprender(mem, m + 152, byte)
        perfilFin(PF_HIP_APR, t1)
        hold v = leer64(variante())
        when sorpresa > lf(m + 48) && v != 2 {
            hold t2 = perfilIni()
            cortezaAprenderRapido(cor, byte, lf(m + 56))
            perfilFin(PF_COR_APR, t2)
        } otherwise {
            escribir64(m + 64, leer64(m + 64) + 1)
        }
        when v == 0 {
            hold t3 = perfilIni()
            mezAprenderRapido(mez, byte)
            perfilFin(PF_MEZ_ACT, t3)
        } otherwise when v == 3 {
            hold tasa = lf(mez + 16)
            ef(mez + 16, tasa / 10.0)
            mezAprenderRapido(mez, byte)
            ef(mez + 16, tasa)
        }
    }
    encaAcabarAvance(cor)
}

// Sueño rápido: solo la corteza.
flow modeloPasoReplayRapido(m: Int, byte: Int) {
    hold cor = leer64(m + 16)
    hold v = leer64(m)
    perfilPaso()
    hold t0 = perfilIni()
    cortezaLeerActivosRapido(cor)
    ventanaEmpujar(v, byte)
    hold b1 = ventanaAtras(v, 1)
    hold b2 = ventanaAtras(v, 2)
    hold b3 = ventanaAtras(v, 3)
    perfilFin(PF_VENTANA, t0)
    encaIniciarAvance(cor, b1, b2, b3, true)
    hold t1 = perfilIni()
    cortezaPredecirRapido(cor)
    perfilFin(PF_COR_LECTURA, t1)
    hold t2 = perfilIni()
    hold sorprendido = sorpresaBits(leerF32(leer64(cor + 216) + byte * 4)) > lf(m + 48)
    perfilFin(PF_REPLAY, t2)
    when sorprendido {
        hold t3 = perfilIni()
        cortezaAprenderRapido(cor, byte, lf(m + 56))
        escribir64(m + 72, leer64(m + 72) + 1)
        perfilFin(PF_COR_APR, t3)
    }
    encaAcabarAvance(cor)
}

expose flow modeloPaso(m: Int, byte: Int, aprender: Bool) {
    when modoRapido(m) {
        modeloPasoRapido(m, byte, aprender)
        give
    }
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold v = leer64(m)
    hold prediccion = modeloPredecirMezcla(m)
    hold pMemoria = lf(mem + 2144 + byte * 8)
    hold pCorteza = lf(leer64(cor + 120) + byte * 8)
    perfilPaso()
    hold tm = perfilIni()
    hold sorpresa = sorpresaBits(lf(leer64(m + 32) + byte * 8))

    escribir64(m + 80, leer64(m + 80) + 1)
    ef(m + 88, lf(m + 88) + sorpresa)
    ef(m + 96, lf(m + 96) + sorpresaBits(pMemoria))
    ef(m + 104, lf(m + 104) + sorpresaBits(pCorteza))
    when prediccion == byte { escribir64(m + 112, leer64(m + 112) + 1) }
    perfilFin(PF_METRICAS, tm)

    when aprender {
        // Los hashes siguen siendo los de la predicción (la ventana no cambió).
        hold t1 = perfilIni()
        memAprender(mem, m + 152, byte)
        perfilFin(PF_HIP_APR, t1)
        when sorpresa > lf(m + 48) {
            hold t2 = perfilIni()
            cortezaAprender(cor, byte, lf(m + 56))
            perfilFin(PF_COR_APR, t2)
        } otherwise {
            escribir64(m + 64, leer64(m + 64) + 1)
        }
        hold t3 = perfilIni()
        mezAprender(leer64(m + 24), byte)
        perfilFin(PF_MEZ_ACT, t3)
    }

    hold t4 = perfilIni()
    ventanaEmpujar(v, byte)
    hold b1 = ventanaAtras(v, 1)
    hold b2 = ventanaAtras(v, 2)
    hold b3 = ventanaAtras(v, 3)
    perfilFin(PF_VENTANA, t4)
    hold t5 = perfilIni()
    cortezaAvanzar(cor, b1, b2, b3, aprender)
    perfilFin(PF_COR_AVANZAR, t5)
}

// Sueño: el corpus se reproduce solo para la corteza; consolida únicamente
// los bytes que aún la sorprenden (> umbral).
expose flow modeloPasoReplay(m: Int, byte: Int) {
    when modoRapido(m) {
        modeloPasoReplayRapido(m, byte)
        give
    }
    hold cor = leer64(m + 16)
    hold v = leer64(m)
    perfilPaso()
    hold t0 = perfilIni()
    cortezaPredecir(cor)
    perfilFin(PF_COR_LECTURA, t0)
    hold t1 = perfilIni()
    hold sorprendido = sorpresaBits(lf(leer64(cor + 120) + byte * 8)) > lf(m + 48)
    perfilFin(PF_REPLAY, t1)
    when sorprendido {
        hold t2 = perfilIni()
        cortezaAprender(cor, byte, lf(m + 56))
        escribir64(m + 72, leer64(m + 72) + 1)
        perfilFin(PF_COR_APR, t2)
    }
    hold t3 = perfilIni()
    ventanaEmpujar(v, byte)
    hold b1 = ventanaAtras(v, 1)
    hold b2 = ventanaAtras(v, 2)
    hold b3 = ventanaAtras(v, 3)
    perfilFin(PF_VENTANA, t3)
    hold t4 = perfilIni()
    cortezaAvanzar(cor, b1, b2, b3, true)
    perfilFin(PF_COR_AVANZAR, t4)
}

// Una pasada de vigilia sobre `texto` (len bytes).
expose flow modeloVigilia(m: Int, texto: Int, len: Int) {
    perfilFase(0)
    encaFijarReparto(leer64(m + 16), 115)
    modeloIniciarDocumento(m)
    each pos among 0..len { modeloPaso(m, leer8(texto + pos), true) }
}

// Una pasada de sueño (replay) sobre `texto`.
expose flow modeloSueno(m: Int, texto: Int, len: Int) {
    perfilFase(1)
    encaFijarReparto(leer64(m + 16), 200)
    modeloIniciarDocumento(m)
    each pos among 0..len { modeloPasoReplay(m, leer8(texto + pos)) }
}

// Evaluación precuencial (exp010): sobre `texto` predice, mide y luego aprende
// con el mismo paso de vigilia del entrenamiento (hipocampo, corteza con su
// compuerta de sorpresa, mezclador). Sin replay ni autocompletado.
expose flow modeloPrecuencial(m: Int, texto: Int, len: Int) {
    modeloVigilia(m, texto, len)
}

// Medida congelada de un documento (hito 21): predice y mide cada byte sin
// aprender y sin autocompletar. Documento nuevo; solo cambian las métricas
// (m + 80...) y el estado transitorio de la corteza, que cada documento
// reconstruye.
expose flow modeloMedirCongelado(m: Int, texto: Int, len: Int) {
    perfilFase(2)
    encaFijarReparto(leer64(m + 16), 140)
    modeloIniciarDocumento(m)
    each pos among 0..len { modeloPaso(m, leer8(texto + pos), false) }
}

flow guardarRespaldo(m: Int) {
    ventanaGuardar(leer64(m))
    cortezaGuardar(leer64(m + 16))
}

flow restaurarRespaldo(m: Int) {
    ventanaRestaurar(leer64(m))
    cortezaRestaurar(leer64(m + 16))
}

expose flow modeloEvaluar(m: Int, texto: Int, longitud: Int) {
    perfilFase(2)
    encaFijarReparto(leer64(m + 16), 140)
    modeloIniciarDocumento(m)
    change noBlancos = 0
    change completada = false
    each pos among 0..longitud {
        when noBlancos == 3 && !completada {
            completada = true
            hold t0 = rdtsc()
            change fin = pos
            during fin < longitud {
                when leer8(texto + fin) == 10 { leave }
                fin += 1
            }
            hold restante = fin - pos
            when restante >= 2 {
                guardarRespaldo(m)
                perfilFase(3)
                change acertados = 0
                each t among 0..restante {
                    perfilPaso()
                    hold generado = modeloPredecirMezcla(m)
                    when generado != leer8(texto + pos + t) { leave }
                    acertados += 1
                    condicionar(m, generado)
                }
                restaurarRespaldo(m)
                perfilFase(2)
                escribir64(m + 120, leer64(m + 120) + 1)
                escribir64(m + 136, leer64(m + 136) + restante)
                escribir64(m + 144, leer64(m + 144) + acertados)
                when acertados == restante { escribir64(m + 128, leer64(m + 128) + 1) }
            }
            escribir64(m + 208, leer64(m + 208) + (rdtsc() - t0))
        }
        hold byte = leer8(texto + pos)
        modeloPaso(m, byte, false)
        when byte == 10 {
            noBlancos = 0
            completada = false
        } otherwise {
            when byte != 32 && byte != 9 && byte != 13 { noBlancos += 1 }
        }
    }
}
