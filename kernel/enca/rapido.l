// ENCA, modo rápido (f32 + SSE + 2 núcleos). El modo exacto no usa nada de
// este archivo.
//
// Qué cambia respecto al modo exacto (f64, bit a bit con Windows):
//  * Capa de salida de la corteza (pesos, sesgo, logits, softmax), expertos y
//    mezcla geométrica en f32 con SSE (4 columnas por instrucción). El
//    softmax usa vexp (lib/vexp.l, 1,35 ulp) con la misma saturación inferior
//    que expFloat: x - máximo se acota a >= -16 (la cota superior no
//    interviene: x <= 0). expFloat es un polinomio ^16 que se aparta de e^x
//    hasta ~5 % en x = -16 (y menos de 3.5e-4 en x = -8); vexp es exp casi
//    exacta: esa es la diferencia sistemática, sin efecto apreciable en bits.
//  * ln del experto del hipocampo: vln (SSE, Cephes logf) en vez de lnRapido.
//  * Hipocampo: el aprendizaje es el mismo (tablas f64); la predicción hace
//    una sola pasada densa en f32 (unigrama * producto de escalas) y suma los
//    pocos símbolos vistos de cada orden ya escalados por las escalas de los
//    órdenes superiores.
//  * La dinámica de la corteza (sinapsis + k-WTA, estado vMem/umbral/activos)
//    pasa en el hito 22 a f32 con SSE (cortezaAvanzarF32, 4 unidades por
//    instrucción y k-WTA con descarte vectorial; ver corteza_bytes.l). Solo
//    depende de los bytes (no de lo que se aprende), así que se calcula en el
//    núcleo 1 mientras el 0 predice y aprende con los activos del paso actual
//    (copia en activosLectura). Antes (hitos 17 a 21) iba en f64 y repartida
//    en dos tramos entre los núcleos; ahora es tan barata que un solo núcleo
//    hace todo el avance.
//
// Determinismo: cada estructura la escribe un solo núcleo a la vez; el
// núcleo 1 solo ejecuta cortezaAvanzarF32 (la misma función que corre el
// núcleo 0 cuando no hay núcleo 1), así que 1 y 2 núcleos dan los mismos bits. Las
// sumas SSE usan siempre 4 sumas parciales por carril y se combinan en el
// orden fijo (l0 + l1) + (l2 + l3).
//
// Registros XMM: el código Float usa XMM0..5; aquí los bucles SSE no
// contienen Float y los acumuladores viven en XMM10..15.

take nucleo.cpu
take nucleo.mem
take lib.consola
take lib.matf64
take lib.vexp
take cpu.buzon
take dispositivos.apic
take enca.matematica
take enca.corteza_bytes
take enca.perfil

expose fixed TRABAJO_ENCA_AVANZAR = 2

// Constantes f32 (una por palabra de 8 bytes; desplazamiento = índice * 8):
//  0 -16  1 1e-9  2 126  3 máscara de mantisa  4 0,5  5 sqrt(1/2)  6 1,0
//  7..15 P0..P8 de logf  16 -2,12194440e-4  17 0,693359375  18 0,1
//  19 -1,0  20 0,0  21 -FLT_MAX
flow kr() => Int {
    give datos64(0xC1800000, 0x3089705F, 0x7E, 0x007FFFFF, 0x3F000000, 0x3F3504F3, 0x3F800000, 0x3D9021BB, 0xBDEBD1B8, 0x3DEF251A, 0xBDFE5D4F, 0x3E11E9BF, 0xBE2AAE50, 0x3E4CCEAC, 0xBE7FFFFC, 0x3EAAAAAA, 0xB95E8083, 0x3F318000, 0x3DCCCCCD, 0xBF800000, 0x00000000, 0xFF7FFFFF)
}

// Zona de trabajo del núcleo 0 (difusiones y reducciones horizontales).
flow esc() => Int { give reservar(256, 64) }

// ---- reducciones horizontales: (l0 + l1) + (l2 + l3) / máximo ----------------
flow suma10() => Float {
    hold e = esc()
    xmmGuardar(e, 10)
    give (leerF32(e) + leerF32(e + 4)) + (leerF32(e + 8) + leerF32(e + 12))
}

flow suma11() => Float {
    hold e = esc()
    xmmGuardar(e, 11)
    give (leerF32(e) + leerF32(e + 4)) + (leerF32(e + 8) + leerF32(e + 12))
}

flow maximo3() => Float {
    hold e = esc()
    xmmGuardar(e, 3)
    change m = leerF32(e)
    each i among 1..4 {
        hold v = leerF32(e + i * 4)
        when v > m { m = v }
    }
    give m
}

flow maximo11() => Float {
    hold e = esc()
    xmmGuardar(e, 11)
    change m = leerF32(e)
    each i among 1..4 {
        hold v = leerF32(e + i * 4)
        when v > m { m = v }
    }
    give m
}

// ---- ln de los 4 floats de XMM1; resultado en XMM8 (usa XMM2..XMM7) ----------
// Cephes logf: x = m * 2^e con m en [0,5; 1); si m < sqrt(1/2): e -= 1,
// x = 2m - 1; si no x = m - 1; ln = x - x²/2 + x³ P(x) + e ln 2. x se acota
// por debajo a 1e-9 (el mismo suelo que usa ENCA).
flow lnRegistro(c: Int) {
    xmmDifundirEn(2, c, 8)
    xmmMaximo(1, 2)
    xmmCopiar(2, 1)
    xmmDesplazarDer(2, 23)
    xmmDifundirEn(3, c, 16)
    xmmRestarEnteros(2, 3)
    xmmAFlotantes(2, 2)
    xmmDifundirEn(3, c, 24)
    xmmY(1, 3)
    xmmDifundirEn(3, c, 32)
    xmmO(1, 3)
    xmmCopiar(4, 1)
    xmmDifundirEn(5, c, 40)
    xmmComparar(4, 5, 1)
    xmmCopiar(5, 1)
    xmmY(5, 4)
    xmmDifundirEn(3, c, 48)
    xmmRestar(1, 3)
    xmmSumar(1, 5)
    xmmY(3, 4)
    xmmRestar(2, 3)
    xmmCopiar(6, 1)
    xmmMultiplicar(6, 1)
    xmmDifundirEn(7, c, 56)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 64)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 72)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 80)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 88)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 96)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 104)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 112)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmDifundirEn(3, c, 120)
    xmmSumar(7, 3)
    xmmMultiplicar(7, 1)
    xmmMultiplicar(7, 6)
    xmmDifundirEn(3, c, 128)
    xmmMultiplicar(3, 2)
    xmmSumar(7, 3)
    xmmDifundirEn(3, c, 32)
    xmmMultiplicar(3, 6)
    xmmRestar(7, 3)
    xmmSumar(1, 7)
    xmmDifundirEn(3, c, 136)
    xmmMultiplicar(3, 2)
    xmmSumar(1, 3)
    xmmCopiar(8, 1)
}

// y[i] = ln(max(x[i], 1e-9)), n múltiplo de 4, búferes alineados a 16.
expose flow vln(x: Int, y: Int, n: Int) {
    hold c = kr()
    change p = 0
    hold bytes = n * 4
    during p < bytes {
        xmmCargar(1, x +% p)
        lnRegistro(c)
        xmmGuardar(y +% p, 8)
        p = p +% 16
    }
}

// Mide vln contra logF (f64) en un barrido geométrico de 1e-9 a 1e6 más un
// barrido lineal en [0,5; 2]. Devuelve true si el error absoluto máximo está
// por debajo de 3e-6 y el relativo (donde |ln x| > 0,1) por debajo de 1e-6.
expose flow vlnMedir(pedidos: Int) => Bool {
    hold lote = 4096
    hold x = reservar(16384, 64)
    hold y = reservar(16384, 64)
    change total = pedidos
    change peorAbs = 0.0
    change peorRel = 0.0
    change ciclos = 0
    change hecho = 0
    hold inicio = rdtsc()
    during hecho < total {
        each i among 0..lote {
            hold t = Float(hecho + i) / Float(total)
            change v = 0.0
            when i % 2 == 0 {
                // geométrico: 1e-9 * 10^(15 t)
                v = 0.000000001 * expF(34.538776394910684 * t)
            } otherwise {
                v = 0.5 + 1.5 * t
            }
            escribirF32(x + i * 4, v)
        }
        hold t0 = rdtsc()
        vln(x, y, lote)
        ciclos += rdtsc() - t0
        each i among 0..lote {
            hold xv = leerF32(x + i * 4)
            hold ref = logF(xv)
            hold err = absF(leerF32(y + i * 4) - ref)
            when err > peorAbs { peorAbs = err }
            when absF(ref) > 0.1 {
                hold rel = err / absF(ref)
                when rel > peorRel { peorRel = rel }
            }
        }
        hecho += lote
        when hecho == lote && total > 65536 && rdtsc() - inicio > 50 * tscCiclosPorMs() {
            total = 65536
        }
    }
    kprint(cadena("vln SSE: "))
    kprintEntero(total)
    kprint(cadena(" valores en [1e-9, 1e6] y [0,5; 2], error absoluto máximo "))
    kprintCientifico(peorAbs, 2)
    kprint(cadena(", relativo (|ln x| > 0,1) "))
    kprintCientifico(peorRel, 2)
    kprint(cadena(", "))
    kprintEntero(ciclos * 100 / total)
    kprintln(cadena(" centésimas de ciclo por valor"))
    give peorAbs < 0.000003 && peorRel < 0.000001
}

// ============================ corteza (f32) ===================================

// Copia el conjunto activo actual (lo deja el último cortezaAvanzar) a
// activosLectura y prepara la dirección de la fila de pesos de cada activo.
expose flow cortezaLeerActivosRapido(z: Int) {
    hold activos = leer64(z + 64)
    hold n = leer64(z + 80)
    hold lectura = leer64(z + 232)
    hold filas = leer64(z + 248)
    hold wF = leer64(z + 192)
    escribir64(z + 240, n)
    each a among 0..n {
        hold u = leer64(activos + a * 8)
        escribir64(lectura + a * 8, u)
        escribir64(filas + a * 8, wF + u * 1024)
    }
}

// logits = sesgo + suma de las filas activas (en orden); softmax con vexp.
// Deja logitsF, distF y logNormalizador (f64, +152); devuelve el logit máximo.
expose flow cortezaPredecirRapido(z: Int) {
    hold c = kr()
    hold ck = vexpConstantes()
    hold n = leer64(z + 240)
    hold filas = leer64(z + 248)
    hold finFilas = filas + n * 8
    hold sesgoF = leer64(z + 200)
    hold logitsF = leer64(z + 208)
    hold distF = leer64(z + 216)
    // XMM1 = 1,0 (multiplicador neutro); XMM3 = máximo corriente.
    xmmDifundirEn(1, c, 48)
    xmmDifundirEn(3, c, 168)
    change col = 0
    during col < 1024 {
        xmmCero(8)
        xmmCero(9)
        xmmCero(10)
        xmmCero(11)
        xmmCero(12)
        xmmCero(13)
        xmmCero(14)
        xmmCero(15)
        hold s = sesgoF +% col
        xmmMulSumar4M(8, 1, s, 0)
        xmmMulSumar4M(12, 1, s, 64)
        change pf = filas
        during pf < finFilas {
            hold fila = leer64(pf) +% col
            xmmMulSumar4M(8, 1, fila, 0)
            xmmMulSumar4M(12, 1, fila, 64)
            pf = pf +% 8
        }
        hold d = logitsF +% col
        xmmGuardar(d, 8)
        xmmGuardar(d +% 16, 9)
        xmmGuardar(d +% 32, 10)
        xmmGuardar(d +% 48, 11)
        xmmGuardar(d +% 64, 12)
        xmmGuardar(d +% 80, 13)
        xmmGuardar(d +% 96, 14)
        xmmGuardar(d +% 112, 15)
        xmmMaximo(8, 9)
        xmmMaximo(10, 11)
        xmmMaximo(12, 13)
        xmmMaximo(14, 15)
        xmmMaximo(8, 10)
        xmmMaximo(12, 14)
        xmmMaximo(8, 12)
        xmmMaximo(3, 8)
        col = col +% 128
    }
    hold maximo = maximo3()
    hold e = esc()
    escribirF32(e, maximo)
    xmmDifundirEn(11, e, 0)
    xmmCero(10)
    change p = 0
    during p < 1024 {
        xmmCargar(1, logitsF +% p)
        xmmRestar(1, 11)
        xmmDifundirEn(2, c, 0)
        xmmMaximo(1, 2)
        expRegistro(ck)
        xmmGuardar(distF +% p, 8)
        xmmSumar(10, 8)
        p = p +% 16
    }
    hold suma = suma10()
    hold inverso = 1.0 / suma
    escribirF32(e, inverso)
    xmmDifundirEn(2, e, 0)
    change q = 0
    during q < 1024 {
        xmmCargar(1, distF +% q)
        xmmMultiplicar(1, 2)
        xmmGuardar(distF +% q, 1)
        q = q +% 16
    }
    ef(z + 152, maximo + lnFloat(suma))
}

// Regla delta local: paso = tasa * (dist - onehot); sesgo -= 0,1 paso;
// w[fila activa] -= paso.
expose flow cortezaAprenderRapido(z: Int, byte: Int, tasa: Float) {
    hold c = kr()
    hold n = leer64(z + 240)
    hold filas = leer64(z + 248)
    hold finFilas = filas + n * 8
    hold sesgoF = leer64(z + 200)
    hold distF = leer64(z + 216)
    hold pasoF = leer64(z + 224)
    hold e = esc()
    escribirF32(e, tasa)
    xmmDifundirEn(2, e, 0)
    change p = 0
    during p < 1024 {
        xmmCargar(1, distF +% p)
        xmmMultiplicar(1, 2)
        xmmGuardar(pasoF +% p, 1)
        p = p +% 16
    }
    hold d = leerF32(distF + byte * 4)
    escribirF32(pasoF + byte * 4, tasa * (d - 1.0))
    xmmDifundirEn(3, c, 144)
    change q = 0
    during q < 1024 {
        xmmCargar(1, pasoF +% q)
        xmmMultiplicar(1, 3)
        xmmCargar(4, sesgoF +% q)
        xmmRestar(4, 1)
        xmmGuardar(sesgoF +% q, 4)
        q = q +% 16
    }
    // XMM1 = -1,0: acumulador + (-1) * paso = acumulador - paso (exacto).
    xmmDifundirEn(1, c, 152)
    change pf = filas
    during pf < finFilas {
        hold fila = leer64(pf)
        change r = 0
        during r < 1024 {
            hold a = fila +% r
            xmmCargar(4, a)
            xmmCargar(5, a +% 16)
            xmmCargar(6, a +% 32)
            xmmCargar(7, a +% 48)
            xmmMulSumar4M(4, 1, pasoF +% r, 0)
            xmmGuardar(a, 4)
            xmmGuardar(a +% 16, 5)
            xmmGuardar(a +% 32, 6)
            xmmGuardar(a +% 48, 7)
            r = r +% 64
        }
        pf = pf +% 8
    }
    escribir64(z + 184, leer64(z + 184) + 1)
}

// ============================ hipocampo (predicción f32) ======================

// Llena distF (m + 4200) con p(siguiente byte | contextos) en f32 y escribe
// ln(max(p, 1e-9)) en `destinoLn` (256 f32, alineado a 16). Mismos niveles y
// mismas escalas Witten-Bell que memPredecir; ordenUsado en m + 72.
// Zona de niveles (m + 4208): por nivel acertado, slot / escala / inverso.
expose flow memPredecirRapido(m: Int, hashes: Int, destinoLn: Int) {
    hold c = kr()
    hold numOrdenes = leer64(m)
    hold slots = leer64(m + 8)
    hold ancho = leer64(m + 16)
    hold etiquetas = leer64(m + 24)
    hold simbolos = leer64(m + 32)
    hold cuentas = leer64(m + 40)
    hold totales = leer64(m + 48)
    hold distintosD = leer64(m + 56)
    hold unigramaF = leer64(m + 4192)
    hold distF = leer64(m + 4200)
    hold zona = m + 4208
    hold denominador = floatDeBits(leer64(m + 64)) + 256.0
    escribir64(m + 72, 0)
    change aciertos = 0
    each nivel among 0..numOrdenes {
        hold hash = leer64(hashes + nivel * 8)
        hold slot = nivel * slots + hash % slots
        when leer64(etiquetas + slot * 8) == hash && floatDeBits(leer64(totales + slot * 8)) > 0.0 {
            hold total = floatDeBits(leer64(totales + slot * 8))
            hold distintos = floatDeBits(leer64(distintosD + slot * 8))
            hold z = zona + aciertos * 32
            escribir64(z, slot)
            ef(z + 8, distintos / (total + distintos))
            ef(z + 16, 1.0 / (total + distintos))
            aciertos += 1
            escribir64(m + 72, nivel + 1)
        }
    }
    // Producto de escalas de los niveles posteriores (z + 24) y total.
    change q = 1.0
    change a = aciertos - 1
    during a >= 0 {
        hold z = zona + a * 32
        ef(z + 24, q)
        q = q * lf(z + 8)
        a -= 1
    }
    hold factor = q / denominador
    hold e = esc()
    escribirF32(e, factor)
    xmmDifundirEn(3, e, 0)
    xmmDifundirEn(2, c, 48)
    change p = 0
    during p < 1024 {
        xmmCargar(1, unigramaF +% p)
        xmmSumar(1, 2)
        xmmMultiplicar(1, 3)
        xmmGuardar(distF +% p, 1)
        p = p +% 16
    }
    each i among 0..aciertos {
        hold z = zona + i * 32
        hold base = leer64(z) * ancho
        hold k = lf(z + 16) * lf(z + 24)
        each j among 0..ancho {
            hold simbolo = leer64(simbolos + (base + j) * 8)
            when simbolo >= 0 {
                hold dir = distF + simbolo * 4
                escribirF32(dir, leerF32(dir) + floatDeBits(leer64(cuentas + (base + j) * 8)) * k)
            }
        }
    }
    change r = 0
    during r < 1024 {
        xmmCargar(1, distF +% r)
        lnRegistro(c)
        xmmGuardar(destinoLn +% r, 8)
        r = r +% 16
    }
}

// ============================ mezclador (f32, 2 expertos) =====================
// Bloque del mezclador (+56...): +56 logE0F  +64 logE1F  +72 zF  +80 distF
//   +88 máximo de z (F)

// Experto 1 = logits de la corteza - logNormalizador (f32).
expose flow mezCargarLogitsRapido(g: Int, logitsF: Int, normalizador: Float) {
    hold destino = leer64(g + 64)
    hold e = esc()
    escribirF32(e, normalizador)
    xmmDifundirEn(2, e, 0)
    change p = 0
    during p < 1024 {
        xmmCargar(1, logitsF +% p)
        xmmRestar(1, 2)
        xmmGuardar(destino +% p, 1)
        p = p +% 16
    }
}

// z = w0 l0 + w1 l1; dist = softmax(z). Guarda el máximo de z (+88).
expose flow mezMezclarRapido(g: Int, contexto: Int) {
    hold c = kr()
    hold ck = vexpConstantes()
    hold pesos = leer64(g + 32)
    hold l0 = leer64(g + 56)
    hold l1 = leer64(g + 64)
    hold zF = leer64(g + 72)
    hold dF = leer64(g + 80)
    escribir64(g + 24, contexto)
    hold e = esc()
    escribirF32(e, lf(pesos + (contexto * 2) * 8))
    escribirF32(e + 8, lf(pesos + (contexto * 2 + 1) * 8))
    xmmDifundirEn(2, e, 0)
    xmmDifundirEn(3, e, 8)
    xmmDifundirEn(11, c, 168)
    change p = 0
    during p < 1024 {
        xmmCargar(1, l0 +% p)
        xmmMultiplicar(1, 2)
        xmmCargar(4, l1 +% p)
        xmmMultiplicar(4, 3)
        xmmSumar(1, 4)
        xmmGuardar(zF +% p, 1)
        xmmMaximo(11, 1)
        p = p +% 16
    }
    hold maximo = maximo11()
    ef(g + 88, maximo)
    escribirF32(e, maximo)
    xmmDifundirEn(11, e, 0)
    xmmCero(10)
    change q = 0
    during q < 1024 {
        xmmCargar(1, zF +% q)
        xmmRestar(1, 11)
        xmmDifundirEn(2, c, 0)
        xmmMaximo(1, 2)
        expRegistro(ck)
        xmmGuardar(dF +% q, 8)
        xmmSumar(10, 8)
        q = q +% 16
    }
    hold inverso = 1.0 / suma10()
    escribirF32(e, inverso)
    xmmDifundirEn(2, e, 0)
    change r = 0
    during r < 1024 {
        xmmCargar(1, dF +% r)
        xmmMultiplicar(1, 2)
        xmmGuardar(dF +% r, 1)
        r = r +% 16
    }
}

// Primer byte con z máximo (el que devuelve mezMezclar).
expose flow mezMejorRapido(g: Int) => Int {
    hold zF = leer64(g + 72)
    hold maximo = lf(g + 88)
    change c = 0
    during c < 256 {
        when leerF32(zF + c * 4) >= maximo { give c }
        c += 1
    }
    give 0
}

expose flow mezAprenderRapido(g: Int, byte: Int) {
    hold pesos = leer64(g + 32)
    hold l0 = leer64(g + 56)
    hold l1 = leer64(g + 64)
    hold dF = leer64(g + 80)
    hold basePesos = leer64(g + 24) * 2
    xmmCero(10)
    xmmCero(11)
    change p = 0
    during p < 1024 {
        xmmCargar(1, dF +% p)
        xmmCargar(4, l0 +% p)
        xmmMultiplicar(4, 1)
        xmmSumar(10, 4)
        xmmCargar(5, l1 +% p)
        xmmMultiplicar(5, 1)
        xmmSumar(11, 5)
        p = p +% 16
    }
    hold esperado0 = suma10()
    hold esperado1 = suma11()
    hold tasa = lf(g + 16)
    hold g0 = leerF32(l0 + byte * 4) - esperado0
    hold g1 = leerF32(l1 + byte * 4) - esperado1
    hold w0 = pesos + basePesos * 8
    hold w1 = w0 + 8
    ef(w0, clampFloat(lf(w0) + tasa * g0, -1.0, 4.0))
    ef(w1, clampFloat(lf(w1) + tasa * g1, -1.0, 4.0))
}

// ============================ dos núcleos =====================================

// Antes repartía el avance de la corteza entre los núcleos; desde el hito 22
// el avance rápido es de un solo núcleo (sin tramos). Se conserva por los
// llamadores (el reparto ya no influye).
expose flow encaFijarReparto(z: Int, unidadesNucleo0: Int) {
    escribir64(z + 320, 0)
}

// Tarea del núcleo 1: todo el avance (cortezaAvanzarF32) con los bytes que dejó
// el núcleo 0 en z + 256..280; su lista queda en puntajes2 / activos2.
expose flow encaTrabajoAvanzar(z: Int) {
    hold t0 = perfilIni()
    hold cuenta = cortezaAvanzarF32(z, leer64(z + 256), leer64(z + 264), leer64(z + 272), leer64(z + 280) != 0)
    escribir64(z + 312, cuenta)
    perfilFin(PF_COR_AVANZAR, t0)
}

// 1 si hay núcleo 1 en línea.
expose flow encaHayNucleo1() => Int {
    when buzonNucleos() > 1 { give 1 }
    give 0
}

// Anota los bytes del avance y, si hay núcleo 1, le encarga el avance.
expose flow encaIniciarAvance(z: Int, b1: Int, b2: Int, b3: Int, plastico: Bool) {
    escribir64(z + 256, b1)
    escribir64(z + 264, b2)
    escribir64(z + 272, b3)
    escribir64(z + 280, 0)
    when plastico { escribir64(z + 280, 1) }
    when buzonNucleos() > 1 { buzonPublicar(1, TRABAJO_ENCA_AVANZAR, z) }
}

// Termina el avance: según haya o no núcleo 1, espera o lo hace el núcleo 0,
// y deja el estado final (listas principales, activos, homeostasis).
expose flow encaAcabarAvance(z: Int) {
    hold plastico = leer64(z + 280) != 0
    when buzonNucleos() > 1 {
        hold t0 = perfilIni()
        buzonEsperarFin(1)
        perfilFin(PF_ESPERA, t0)
    } otherwise {
        hold t1 = perfilIni()
        escribir64(z + 312, cortezaAvanzarF32(z, leer64(z + 256), leer64(z + 264), leer64(z + 272), plastico))
        perfilFin(PF_COR_AVANZAR, t1)
    }
    hold t3 = perfilIni()
    cortezaCerrarF32(z, leer64(z + 312), plastico)
    perfilFin(PF_COR_AVANZAR, t3)
}
