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

take nucleo.cpu
take nucleo.mem
take enca.matematica
take enca.ventana
take enca.memoria_secuencial
take enca.corteza_bytes
take enca.mezclador_geometrico

flow sorpresaBits(p: Float) => Float {
    give 0.0 - lnRapido(maxFloat(p, 0.000000001)) * 1.4426950408889634
}

expose flow modeloCrear(slots: Int) => Int {
    hold m = ncaReservar(224)
    hold mezcla = ncaReservar(256 * 8)
    when m == 0 || mezcla == 0 { give 0 }
    each j among 0..28 { escribir64(m + j * 8, 0) }
    each c among 0..256 { ef(mezcla + c * 8, 0.00390625) }
    ef(m + 192, 1.0)
    ef(m + 200, 0.2)
    escribir64(m, ventanaCrear(8))
    escribir64(m + 8, memCrear(5, slots, 12))
    escribir64(m + 16, cortezaCrear(512, 16, 2026))
    escribir64(m + 24, mezCrear(6, 2, 0.003, m + 192))
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

expose flow modeloPredecirMezcla(m: Int) => Int {
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold mez = leer64(m + 24)
    calcularHashes(m)
    memPredecir(mem, m + 152)
    cortezaPredecir(cor)
    escribir64(m + 40, leer64(mem + 72))
    mezCargarProbabilidades(mez, 0, mem + 2144)
    mezCargarLogits(mez, 1, leer64(cor + 112), lf(cor + 152))
    hold mejor = mezMezclar(mez, leer64(m + 40))
    hold mezcla = leer64(m + 32)
    hold distMez = leer64(mez + 48)
    each c among 0..256 { escribir64(mezcla + c * 8, leer64(distMez + c * 8)) }
    give mejor
}

flow condicionar(m: Int, byte: Int) {
    hold v = leer64(m)
    ventanaEmpujar(v, byte)
    cortezaAvanzar(leer64(m + 16), ventanaAtras(v, 1), ventanaAtras(v, 2), ventanaAtras(v, 3), false)
}

// Vigilia: predecir, medir, aprender (hipocampo siempre; corteza con
// compuerta sobre la sorpresa de la mezcla; mezclador), avanzar.
expose flow modeloPaso(m: Int, byte: Int, aprender: Bool) {
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold v = leer64(m)
    hold prediccion = modeloPredecirMezcla(m)
    hold pMemoria = lf(mem + 2144 + byte * 8)
    hold pCorteza = lf(leer64(cor + 120) + byte * 8)
    hold sorpresa = sorpresaBits(lf(leer64(m + 32) + byte * 8))

    escribir64(m + 80, leer64(m + 80) + 1)
    ef(m + 88, lf(m + 88) + sorpresa)
    ef(m + 96, lf(m + 96) + sorpresaBits(pMemoria))
    ef(m + 104, lf(m + 104) + sorpresaBits(pCorteza))
    when prediccion == byte { escribir64(m + 112, leer64(m + 112) + 1) }

    when aprender {
        // Los hashes siguen siendo los de la predicción (la ventana no cambió).
        memAprender(mem, m + 152, byte)
        when sorpresa > lf(m + 48) {
            cortezaAprender(cor, byte, lf(m + 56))
        } otherwise {
            escribir64(m + 64, leer64(m + 64) + 1)
        }
        mezAprender(leer64(m + 24), byte)
    }

    ventanaEmpujar(v, byte)
    cortezaAvanzar(cor, ventanaAtras(v, 1), ventanaAtras(v, 2), ventanaAtras(v, 3), aprender)
}

// Sueño: el corpus se reproduce solo para la corteza; consolida únicamente
// los bytes que aún la sorprenden (> umbral).
expose flow modeloPasoReplay(m: Int, byte: Int) {
    hold cor = leer64(m + 16)
    hold v = leer64(m)
    cortezaPredecir(cor)
    when sorpresaBits(lf(leer64(cor + 120) + byte * 8)) > lf(m + 48) {
        cortezaAprender(cor, byte, lf(m + 56))
        escribir64(m + 72, leer64(m + 72) + 1)
    }
    ventanaEmpujar(v, byte)
    cortezaAvanzar(cor, ventanaAtras(v, 1), ventanaAtras(v, 2), ventanaAtras(v, 3), true)
}

// Una pasada de vigilia sobre `texto` (len bytes).
expose flow modeloVigilia(m: Int, texto: Int, len: Int) {
    modeloIniciarDocumento(m)
    each pos among 0..len { modeloPaso(m, leer8(texto + pos), true) }
}

// Una pasada de sueño (replay) sobre `texto`.
expose flow modeloSueno(m: Int, texto: Int, len: Int) {
    modeloIniciarDocumento(m)
    each pos among 0..len { modeloPasoReplay(m, leer8(texto + pos)) }
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
                change acertados = 0
                each t among 0..restante {
                    hold generado = modeloPredecirMezcla(m)
                    when generado != leer8(texto + pos + t) { leave }
                    acertados += 1
                    condicionar(m, generado)
                }
                restaurarRespaldo(m)
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
