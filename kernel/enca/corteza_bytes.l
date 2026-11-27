// ENCA: corteza dispersa para predicción autoregresiva de bytes (port literal
// de corteza_bytes.l). Sinapsis de entrada procedurales (tabla uniforme de
// 4096 valores indexada por Lehmer), dinámica multiescala, k-WTA por
// inserción ordenada, homeostasis y lectura softmax con las k activas.
//
// Bloque (384 bytes, 8 por campo; Float con los bits IEEE):
//   +0 n  +8 k  +16 semilla  +24 tasaObjetivo(F)  +32 tasaHomeostatica(F)
//   +40 vMem(F, n)  +48 decaimiento(F, n)  +56 umbral(F, n)
//   +64 activos(Int, k)  +72 puntaje(F, k)  +80 numActivos
//   +88 tablaUniforme(F, 4096)  +96 wSalida(F, n*256)  +104 sesgo(F, 256)
//   +112 logits(F, 256)  +120 distribucion(F, 256)  +128 vRespaldo(F, n)
//   +136 activosRespaldo(Int, k)  +144 numActivosRespaldo
//   +152 logNormalizador(F)  +160 pasos(F, 256; temporal del aprendizaje)
//   +168 tablas de impulso R (F, 3 retardos x 257 bytes x n): R[r][b][i] es el
//        término del retardo r+1 para la unidad i (retardo 2 ya x 0,6 y
//        retardo 3 ya x 0,35: el mismo producto que calculaba cada paso)
//   +176 unoMenosFuga(F, n) = 1,0 - decaimiento
//   +184 actualizaciones
// Modo rápido (f32, ver enca/rapido.l; solo se reservan con modo = 1):
//   +192 wF(f32, n*256)  +200 sesgoF(f32,256)  +208 logitsF  +216 distF
//   +224 pasoF  +232 activosLectura(Int, k)  +240 numActivosLectura
//   +248 filas(Int, k)  +256 b1  +264 b2  +272 b3  +280 plastico (trabajo del núcleo 1)
//   +288 (libre)  +296 puntajes2(F, k)  +304 activos2(Int, k)  +312 cuenta2
//   +320 unidades del tramo del núcleo 0 (el resto va al núcleo 1)
//   +328 puntajes3(F, k)  +336 activos3(Int, k)  (salida de la fusión; se intercambian con z+72 / z+64)
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

expose flow cortezaCrear(n: Int, k: Int, semilla: Int, modo: Int) => Int {
    hold z = ncaReservar(384)
    hold vMem = ncaReservar(n * 8)
    hold decaimiento = ncaReservar(n * 8)
    hold umbral = ncaReservar(n * 8)
    hold vRespaldo = ncaReservar(n * 8)
    hold activos = ncaReservar(k * 8)
    hold activosRespaldo = ncaReservar(k * 8)
    hold puntaje = ncaReservar(k * 8)
    hold tabla = ncaReservar(4096 * 8)
    change tamW = n * 256 * 8
    when modo == 1 { tamW = 8 }
    hold wSalida = ncaReservar(tamW)
    hold sesgo = ncaReservar(256 * 8)
    hold logits = ncaReservar(256 * 8)
    hold distribucion = ncaReservar(256 * 8)
    hold pasos = ncaReservar(256 * 8)
    hold tablasR = ncaReservar(3 * 257 * n * 8)
    hold omf = ncaReservar(n * 8)
    when z == 0 || pasos == 0 || tablasR == 0 || omf == 0 || vMem == 0 || decaimiento == 0 || umbral == 0 || vRespaldo == 0 || activos == 0 || activosRespaldo == 0 || puntaje == 0 || tabla == 0 || wSalida == 0 || sesgo == 0 || logits == 0 || distribucion == 0 { give 0 }
    each i among 0..n {
        ef(vMem + i * 8, 0.0)
        ef(umbral + i * 8, 0.0)
        ef(vRespaldo + i * 8, 0.0)
        change fuga = 0.0
        when i * 4 >= n { fuga = 0.5 }
        when i * 2 >= n { fuga = 0.8 }
        when i * 4 >= n * 3 { fuga = 0.95 }
        ef(decaimiento + i * 8, fuga)
        ef(omf + i * 8, 1.0 - fuga)
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
    when modo == 0 {
        each w among 0..n * 256 { escribir64(wSalida + w * 8, 0) }
    }
    // Tablas de impulso: mismas operaciones del bucle original, hechas una vez.
    each r among 0..3 {
        each b among 0..257 {
            change idx = origenProcedural(semilla, r + 1, b)
            hold paso = pasoProcedural(semilla, r + 1, b)
            hold fila = tablasR + ((r * 257 + b) * n) * 8
            each i among 0..n {
                idx += paso
                when idx >= 4096 { idx -= 4096 }
                hold t = lf(tabla + idx * 8)
                when r == 0 { ef(fila + i * 8, t) }
                when r == 1 { ef(fila + i * 8, 0.6 * t) }
                when r == 2 { ef(fila + i * 8, 0.35 * t) }
            }
        }
    }
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
    escribir64(z + 160, pasos)
    escribir64(z + 168, tablasR)
    escribir64(z + 176, omf)
    escribir64(z + 184, 0)
    when modo == 1 {
        hold puntajes2 = ncaReservar(k * 8)
        hold activos2 = ncaReservar(k * 8)
        when puntajes2 == 0 || activos2 == 0 { give 0 }
        escribir64(z + 296, puntajes2)
        escribir64(z + 304, activos2)
        escribir64(z + 312, 0)
        escribir64(z + 320, n / 2)
        hold puntajes3 = ncaReservar(k * 8)
        hold activos3 = ncaReservar(k * 8)
        when puntajes3 == 0 || activos3 == 0 { give 0 }
        escribir64(z + 328, puntajes3)
        escribir64(z + 336, activos3)
        hold wF = ncaReservarAlineado(n * 256 * 4)
        hold sesgoF = ncaReservarAlineado(256 * 4)
        hold logitsF = ncaReservarAlineado(256 * 4)
        hold distF = ncaReservarAlineado(256 * 4)
        hold pasoF = ncaReservarAlineado(256 * 4)
        hold lectura = ncaReservar(k * 8)
        hold filas = ncaReservar(k * 8)
        when wF == 0 || sesgoF == 0 || logitsF == 0 || distF == 0 || pasoF == 0 || lectura == 0 || filas == 0 { give 0 }
        each w among 0..n * 128 { escribir64(wF + w * 8, 0) }
        each c among 0..128 {
            escribir64(sesgoF + c * 8, 0)
            escribir64(logitsF + c * 8, 0)
            escribir64(distF + c * 8, 0)
            escribir64(pasoF + c * 8, 0)
        }
        each a among 0..k {
            escribir64(lectura + a * 8, 0)
            escribir64(filas + a * 8, 0)
        }
        escribir64(z + 192, wF)
        escribir64(z + 200, sesgoF)
        escribir64(z + 208, logitsF)
        escribir64(z + 216, distF)
        escribir64(z + 224, pasoF)
        escribir64(z + 232, lectura)
        escribir64(z + 240, 0)
        escribir64(z + 248, filas)
        escribir64(z + 256, 0)
        escribir64(z + 264, 0)
        escribir64(z + 272, 0)
        escribir64(z + 280, 0)
        escribir64(z + 288, 0)
    }
    give z
}

expose flow cortezaReiniciar(z: Int) {
    hold vMem = leer64(z + 40)
    each i among 0..leer64(z) { ef(vMem + i * 8, 0.0) }
    escribir64(z + 80, 0)
}

// Integra los tres últimos bytes y selecciona el Centro Dinámico (k-WTA).
// Optimizada sin cambiar la matemática: los tres términos de impulso salen de
// las tablas R (mismos valores que daba tabla[i] x constante), 1,0 - fuga
// está precalculado, los accesos van por desplazamiento (sin llamadas) y el
// puntaje del último activo ("corte") vive en un local.
//
// Se divide en tramos para poder repartirlos entre núcleos sin cambiar nada:
//  * cortezaAvanzarTramo(desde, hasta): actualiza vMem de las unidades del
//    tramo, elige los k mejores del tramo (puntaje desc., índice asc.) y, si
//    es plástico, baja sus umbrales.
//  * cortezaFusionar: mezcla dos listas de tramos contiguos (el resultado es
//    el mismo que recorrer todas las unidades en orden).
//  * cortezaAvanzarFin: guarda el número de activos y sube el umbral de
//    los activos.
// Devuelve cuántos activos tiene el tramo.
expose flow cortezaAvanzarTramo(z: Int, b1: Int, b2: Int, b3: Int, desde: Int, hasta: Int, plastico: Bool, puntajes: Int, activos: Int) => Int {
    hold n = leer64(z)
    hold k = leer64(z + 8)
    hold vMem = leer64(z + 40)
    hold decaimiento = leer64(z + 48)
    hold umbral = leer64(z + 56)
    hold tablasR = leer64(z + 168)
    hold omf = leer64(z + 176)
    hold paso = n * 8
    hold r1 = tablasR + (b1 * paso)
    hold r2 = tablasR + ((257 + b2) * paso)
    hold r3 = tablasR + ((514 + b3) * paso)
    hold fin = hasta * 8
    change numActivos = 0
    change corte = -1.0e308
    change o = desde * 8
    during o < fin {
        hold impulso = floatDeBits(leer64(r1 +% o)) + floatDeBits(leer64(r2 +% o)) + floatDeBits(leer64(r3 +% o))
        hold v = floatDeBits(leer64(decaimiento +% o)) * floatDeBits(leer64(vMem +% o)) + floatDeBits(leer64(omf +% o)) * impulso
        escribir64(vMem +% o, bitsDeFloat(v))
        hold puntaje = v - floatDeBits(leer64(umbral +% o))
        // Mientras la lista no esté llena `corte` es -1e308: todo puntaje entra.
        when puntaje > corte {
            change posicion = k - 1
            when numActivos < k {
                posicion = numActivos
                numActivos += 1
            }
            during posicion > 0 {
                hold previo = floatDeBits(leer64(puntajes + (posicion - 1) * 8))
                when previo >= puntaje { leave }
                escribir64(puntajes + posicion * 8, bitsDeFloat(previo))
                escribir64(activos + posicion * 8, leer64(activos + (posicion - 1) * 8))
                posicion -= 1
            }
            escribir64(puntajes + posicion * 8, bitsDeFloat(puntaje))
            escribir64(activos + posicion * 8, o >> 3)
            when numActivos == k { corte = floatDeBits(leer64(puntajes + (k - 1) * 8)) }
        }
        o = o +% 8
    }
    when plastico {
        hold bajada = lf(z + 32) * lf(z + 24)
        change q = desde * 8
        during q < fin {
            escribir64(umbral +% q, bitsDeFloat(floatDeBits(leer64(umbral +% q)) - bajada))
            q = q +% 8
        }
    }
    give numActivos
}

// Mezcla ordenada de la lista principal (z + 72 / z + 64, cuentaA elementos)
// con la del tramo siguiente (p2, a2, cuentaB): se toman los k mejores por
// puntaje descendente; a igual puntaje gana la lista principal (índices
// menores). Es el mismo resultado que insertar en orden de unidad. El
// resultado se arma en las listas +328/+336 y se intercambian con las
// principales (sin copiar). Devuelve el total.
expose flow cortezaFusionar(z: Int, cuentaA: Int, p2: Int, a2: Int, cuentaB: Int) => Int {
    hold k = leer64(z + 8)
    hold activosA = leer64(z + 64)
    hold puntajesA = leer64(z + 72)
    hold puntajesO = leer64(z + 328)
    hold activosO = leer64(z + 336)
    change i = 0
    change j = 0
    change o = 0
    during o < k {
        when i >= cuentaA && j >= cuentaB { leave }
        change tomarA = false
        when i < cuentaA {
            when j >= cuentaB {
                tomarA = true
            } otherwise {
                when floatDeBits(leer64(puntajesA + i * 8)) >= floatDeBits(leer64(p2 + j * 8)) { tomarA = true }
            }
        }
        when tomarA {
            escribir64(puntajesO + o * 8, leer64(puntajesA + i * 8))
            escribir64(activosO + o * 8, leer64(activosA + i * 8))
            i += 1
        } otherwise {
            escribir64(puntajesO + o * 8, leer64(p2 + j * 8))
            escribir64(activosO + o * 8, leer64(a2 + j * 8))
            j += 1
        }
        o += 1
    }
    escribir64(z + 64, activosO)
    escribir64(z + 72, puntajesO)
    escribir64(z + 336, activosA)
    escribir64(z + 328, puntajesA)
    give o
}

expose flow cortezaAvanzarFin(z: Int, numActivos: Int, plastico: Bool) {
    escribir64(z + 80, numActivos)
    when plastico {
        hold umbral = leer64(z + 56)
        hold activos = leer64(z + 64)
        hold tasaHomeo = lf(z + 32)
        each a among 0..numActivos {
            hold u = umbral + leer64(activos + a * 8) * 8
            escribir64(u, bitsDeFloat(floatDeBits(leer64(u)) + tasaHomeo))
        }
    }
}

expose flow cortezaAvanzar(z: Int, b1: Int, b2: Int, b3: Int, plastico: Bool) {
    hold n = leer64(z)
    hold cuenta = cortezaAvanzarTramo(z, b1, b2, b3, 0, n, plastico, leer64(z + 72), leer64(z + 64))
    cortezaAvanzarFin(z, cuenta, plastico)
}

// Softmax sobre 256 bytes usando solo las k unidades activas (binarias).
// Los logits se acumulan por filas de wSalida (contiguas): cada logit suma
// sesgo + w[a0] + w[a1] + ... en el mismo orden que la versión por columnas.
expose flow cortezaPredecir(z: Int) {
    hold numActivos = leer64(z + 80)
    hold activos = leer64(z + 64)
    hold wSalida = leer64(z + 96)
    hold sesgo = leer64(z + 104)
    hold logits = leer64(z + 112)
    hold dist = leer64(z + 120)
    hold finLogits = logits + 2048
    change o = 0
    during o < 2048 {
        escribir64(logits +% o, leer64(sesgo +% o))
        o = o +% 8
    }
    each a among 0..numActivos {
        hold fila = wSalida + leer64(activos + a * 8) * 2048
        change p = logits
        change q = fila
        during p < finLogits {
            escribir64(p, bitsDeFloat(floatDeBits(leer64(p)) + floatDeBits(leer64(q))))
            p = p +% 8
            q = q +% 8
        }
    }
    change maximo = -1.0e30
    change pm = logits
    during pm < finLogits {
        hold zz = floatDeBits(leer64(pm))
        when zz > maximo { maximo = zz }
        pm = pm +% 8
    }
    // expFloat(x) en línea (mismas operaciones y orden que matematica.l).
    change suma = 0.0
    change pe = logits
    change pd = dist
    during pe < finLogits {
        change x = floatDeBits(leer64(pe)) - maximo
        when x < -16.0 { x = -16.0 }
        when x > 16.0 { x = 16.0 }
        hold reduced = x * 0.0625
        hold x2 = reduced * reduced
        hold x3 = x2 * reduced
        hold x4 = x3 * reduced
        hold x5 = x4 * reduced
        change e = 1.0 + reduced + x2 * 0.5 + x3 / 6.0 + x4 / 24.0 + x5 / 120.0
        e = e * e
        e = e * e
        e = e * e
        e = e * e
        escribir64(pd, bitsDeFloat(e))
        suma += e
        pe = pe +% 8
        pd = pd +% 8
    }
    hold inverso = 1.0 / suma
    change pn = dist
    hold finDist = dist + 2048
    during pn < finDist {
        escribir64(pn, bitsDeFloat(floatDeBits(leer64(pn)) * inverso))
        pn = pn +% 8
    }
    // log q(c) = logits[c] - logNormalizador.
    ef(z + 152, maximo + lnFloat(suma))
}

// Regla delta local (entropía cruzada) restringida a sinapsis activas.
// El paso de cada clase se calcula una vez (256 valores) y las filas activas
// se actualizan en orden de memoria; cada peso recibe la misma resta.
expose flow cortezaAprender(z: Int, byte: Int, tasa: Float) {
    hold numActivos = leer64(z + 80)
    hold activos = leer64(z + 64)
    hold wSalida = leer64(z + 96)
    hold sesgo = leer64(z + 104)
    hold dist = leer64(z + 120)
    hold pasos = leer64(z + 160)
    each c among 0..256 {
        change delta = floatDeBits(leer64(dist + c * 8))
        when c == byte { delta -= 1.0 }
        hold paso = tasa * delta
        escribir64(pasos + c * 8, bitsDeFloat(paso))
        escribir64(sesgo + c * 8, bitsDeFloat(floatDeBits(leer64(sesgo + c * 8)) - 0.1 * paso))
    }
    hold finPasos = pasos + 2048
    each a among 0..numActivos {
        change w = wSalida + leer64(activos + a * 8) * 2048
        change q = pasos
        during q < finPasos {
            escribir64(w, bitsDeFloat(floatDeBits(leer64(w)) - floatDeBits(leer64(q))))
            w = w +% 8
            q = q +% 8
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
