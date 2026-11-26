// ENCA: corteza dispersa para predicción autoregresiva de bytes (port literal
// de corteza_bytes.l). Sinapsis de entrada procedurales (tabla uniforme de
// 4096 valores indexada por Lehmer), dinámica multiescala, k-WTA por
// inserción ordenada, homeostasis y lectura softmax con las k activas.
//
// Bloque (192 bytes, 8 por campo; Float con los bits IEEE):
//   +0 n  +8 k  +16 semilla  +24 tasaObjetivo(F)  +32 tasaHomeostatica(F)
//   +40 vMem(F, n)  +48 decaimiento(F, n)  +56 umbral(F, n)
//   +64 activos(Int, k)  +72 puntaje(F, k)  +80 numActivos
//   +88 tablaUniforme(F, 4096)  +96 wSalida(F, n*256)  +104 sesgo(F, 256)
//   +112 logits(F, 256)  +120 distribucion(F, 256)  +128 vRespaldo(F, n)
//   +136 activosRespaldo(Int, k)  +144 numActivosRespaldo
//   +152 logNormalizador(F)  +184 actualizaciones
// (los contadores de MACs del original no se usan en C5 y se omiten)

take nucleo.cpu
take nucleo.mem
take enca.matematica

flow lehmer(valor: Int) => Int {
    give (valor * 48271) % 2147483647
}

flow semillaProcedural(semilla: Int, retardo: Int, byte: Int) => Int {
    give (semilla * 16807 + retardo * 104729 + byte * 7919 + 12345) % 2147483647
}

flow origenProcedural(semilla: Int, retardo: Int, byte: Int) => Int {
    give lehmer(lehmer(semillaProcedural(semilla, retardo, byte))) % 4096
}

// Paso impar (coprimo con 4096).
flow pasoProcedural(semilla: Int, retardo: Int, byte: Int) => Int {
    give (lehmer(lehmer(lehmer(semillaProcedural(semilla, retardo, byte)))) % 2048) * 2 + 1
}

expose flow cortezaCrear(n: Int, k: Int, semilla: Int) => Int {
    hold z = ncaReservar(192)
    hold vMem = ncaReservar(n * 8)
    hold decaimiento = ncaReservar(n * 8)
    hold umbral = ncaReservar(n * 8)
    hold vRespaldo = ncaReservar(n * 8)
    hold activos = ncaReservar(k * 8)
    hold activosRespaldo = ncaReservar(k * 8)
    hold puntaje = ncaReservar(k * 8)
    hold tabla = ncaReservar(4096 * 8)
    hold wSalida = ncaReservar(n * 256 * 8)
    hold sesgo = ncaReservar(256 * 8)
    hold logits = ncaReservar(256 * 8)
    hold distribucion = ncaReservar(256 * 8)
    when z == 0 || vMem == 0 || decaimiento == 0 || umbral == 0 || vRespaldo == 0 || activos == 0 || activosRespaldo == 0 || puntaje == 0 || tabla == 0 || wSalida == 0 || sesgo == 0 || logits == 0 || distribucion == 0 { give 0 }
    each i among 0..n {
        ef(vMem + i * 8, 0.0)
        ef(umbral + i * 8, 0.0)
        ef(vRespaldo + i * 8, 0.0)
        change fuga = 0.0
        when i * 4 >= n { fuga = 0.5 }
        when i * 2 >= n { fuga = 0.8 }
        when i * 4 >= n * 3 { fuga = 0.95 }
        ef(decaimiento + i * 8, fuga)
    }
    each a among 0..k {
        escribir64(activos + a * 8, 0)
        escribir64(activosRespaldo + a * 8, 0)
        ef(puntaje + a * 8, 0.0)
    }
    change valor = -1.0 + 0.000244140625
    each t among 0..4096 {
        ef(tabla + t * 8, valor)
        valor += 0.00048828125
    }
    each w among 0..n * 256 { escribir64(wSalida + w * 8, 0) }
    each c among 0..256 {
        ef(sesgo + c * 8, 0.0)
        ef(logits + c * 8, 0.0)
        ef(distribucion + c * 8, 0.00390625)
    }
    escribir64(z, n)
    escribir64(z + 8, k)
    escribir64(z + 16, semilla)
    ef(z + 24, intToFloat(k) / intToFloat(n))
    ef(z + 32, 0.01)
    escribir64(z + 40, vMem)
    escribir64(z + 48, decaimiento)
    escribir64(z + 56, umbral)
    escribir64(z + 64, activos)
    escribir64(z + 72, puntaje)
    escribir64(z + 80, 0)
    escribir64(z + 88, tabla)
    escribir64(z + 96, wSalida)
    escribir64(z + 104, sesgo)
    escribir64(z + 112, logits)
    escribir64(z + 120, distribucion)
    escribir64(z + 128, vRespaldo)
    escribir64(z + 136, activosRespaldo)
    escribir64(z + 144, 0)
    ef(z + 152, 0.0)
    escribir64(z + 160, 0)
    escribir64(z + 168, 0)
    escribir64(z + 176, 0)
    escribir64(z + 184, 0)
    give z
}

expose flow cortezaReiniciar(z: Int) {
    hold vMem = leer64(z + 40)
    each i among 0..leer64(z) { ef(vMem + i * 8, 0.0) }
    escribir64(z + 80, 0)
}

// Integra los tres últimos bytes y selecciona el Centro Dinámico (k-WTA).
expose flow cortezaAvanzar(z: Int, b1: Int, b2: Int, b3: Int, plastico: Bool) {
    hold n = leer64(z)
    hold k = leer64(z + 8)
    hold semilla = leer64(z + 16)
    hold vMem = leer64(z + 40)
    hold decaimiento = leer64(z + 48)
    hold umbral = leer64(z + 56)
    hold activos = leer64(z + 64)
    hold puntajes = leer64(z + 72)
    hold tabla = leer64(z + 88)
    change i1 = origenProcedural(semilla, 1, b1)
    hold s1 = pasoProcedural(semilla, 1, b1)
    change i2 = origenProcedural(semilla, 2, b2)
    hold s2 = pasoProcedural(semilla, 2, b2)
    change i3 = origenProcedural(semilla, 3, b3)
    hold s3 = pasoProcedural(semilla, 3, b3)
    change numActivos = 0
    each i among 0..n {
        i1 += s1
        when i1 >= 4096 { i1 -= 4096 }
        i2 += s2
        when i2 >= 4096 { i2 -= 4096 }
        i3 += s3
        when i3 >= 4096 { i3 -= 4096 }
        hold impulso = lf(tabla + i1 * 8) + 0.6 * lf(tabla + i2 * 8) + 0.35 * lf(tabla + i3 * 8)
        hold fuga = lf(decaimiento + i * 8)
        hold v = fuga * lf(vMem + i * 8) + (1.0 - fuga) * impulso
        ef(vMem + i * 8, v)
        hold puntaje = v - lf(umbral + i * 8)
        change insertar = false
        change posicion = numActivos
        when numActivos < k {
            insertar = true
            numActivos += 1
        } otherwise {
            when puntaje > lf(puntajes + (k - 1) * 8) {
                insertar = true
                posicion = k - 1
            }
        }
        when insertar {
            during posicion > 0 {
                when lf(puntajes + (posicion - 1) * 8) >= puntaje { leave }
                ef(puntajes + posicion * 8, lf(puntajes + (posicion - 1) * 8))
                escribir64(activos + posicion * 8, leer64(activos + (posicion - 1) * 8))
                posicion -= 1
            }
            ef(puntajes + posicion * 8, puntaje)
            escribir64(activos + posicion * 8, i)
        }
    }
    escribir64(z + 80, numActivos)
    when plastico {
        hold bajada = lf(z + 32) * lf(z + 24)
        each i among 0..n { ef(umbral + i * 8, lf(umbral + i * 8) - bajada) }
        each a among 0..numActivos {
            hold u = umbral + leer64(activos + a * 8) * 8
            ef(u, lf(u) + lf(z + 32))
        }
    }
}

// Softmax sobre 256 bytes usando solo las k unidades activas (binarias).
expose flow cortezaPredecir(z: Int) {
    hold numActivos = leer64(z + 80)
    hold activos = leer64(z + 64)
    hold wSalida = leer64(z + 96)
    hold sesgo = leer64(z + 104)
    hold logits = leer64(z + 112)
    hold dist = leer64(z + 120)
    change maximo = -1.0e30
    each c among 0..256 {
        change zz = lf(sesgo + c * 8)
        each a among 0..numActivos {
            zz += lf(wSalida + (leer64(activos + a * 8) * 256 + c) * 8)
        }
        ef(logits + c * 8, zz)
        when zz > maximo { maximo = zz }
    }
    change suma = 0.0
    each c among 0..256 {
        hold e = expFloat(lf(logits + c * 8) - maximo)
        ef(dist + c * 8, e)
        suma += e
    }
    hold inverso = 1.0 / suma
    each c among 0..256 {
        ef(dist + c * 8, lf(dist + c * 8) * inverso)
    }
    // log q(c) = logits[c] - logNormalizador.
    ef(z + 152, maximo + lnFloat(suma))
}

// Regla delta local (entropía cruzada) restringida a sinapsis activas.
expose flow cortezaAprender(z: Int, byte: Int, tasa: Float) {
    hold numActivos = leer64(z + 80)
    hold activos = leer64(z + 64)
    hold wSalida = leer64(z + 96)
    hold sesgo = leer64(z + 104)
    hold dist = leer64(z + 120)
    each c among 0..256 {
        change delta = lf(dist + c * 8)
        when c == byte { delta -= 1.0 }
        hold paso = tasa * delta
        ef(sesgo + c * 8, lf(sesgo + c * 8) - 0.1 * paso)
        each a among 0..numActivos {
            hold w = wSalida + (leer64(activos + a * 8) * 256 + c) * 8
            ef(w, lf(w) - paso)
        }
    }
    escribir64(z + 184, leer64(z + 184) + 1)
}

expose flow cortezaGuardar(z: Int) {
    hold vMem = leer64(z + 40)
    hold vResp = leer64(z + 128)
    each i among 0..leer64(z) { escribir64(vResp + i * 8, leer64(vMem + i * 8)) }
    each a among 0..leer64(z + 8) { escribir64(leer64(z + 136) + a * 8, leer64(leer64(z + 64) + a * 8)) }
    escribir64(z + 144, leer64(z + 80))
}

expose flow cortezaRestaurar(z: Int) {
    hold vMem = leer64(z + 40)
    hold vResp = leer64(z + 128)
    each i among 0..leer64(z) { escribir64(vMem + i * 8, leer64(vResp + i * 8)) }
    each a among 0..leer64(z + 8) { escribir64(leer64(z + 64) + a * 8, leer64(leer64(z + 136) + a * 8)) }
    escribir64(z + 80, leer64(z + 144))
}
