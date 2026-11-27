// ENCA: mezclador geométrico (producto de expertos) con pesos aprendidos por
// contexto, port literal de mezclador_geometrico.l.
//   log p(c) = sum_e w[ctx, e] * log p_e(c) - log Z
//
// Bloque (56 bytes):
//   +0 numContextos  +8 numExpertos  +16 tasa(F)  +24 contexto
//   +32 pesos(F, numContextos*numExpertos)  +40 logExpertos(F, numExpertos*256)
//   +48 distribucion(F, 256)
// Modo rápido (modo = 1): +56 logE0F  +64 logE1F  +72 zF  +80 distF (f32, 256,
//   alineados a 64)  +88 máximo de z (F). Bloque de 96 bytes.

take nucleo.cpu
take nucleo.mem
take enca.matematica

// iniciales: dir de numExpertos Float.
expose flow mezCrear(numContextos: Int, numExpertos: Int, tasa: Float, iniciales: Int, modo: Int) => Int {
    hold g = ncaReservar(96)
    hold pesos = ncaReservar(numContextos * numExpertos * 8)
    hold logExpertos = ncaReservar(numExpertos * 256 * 8)
    hold distribucion = ncaReservar(256 * 8)
    when g == 0 || pesos == 0 || logExpertos == 0 || distribucion == 0 { give 0 }
    each ctx among 0..numContextos {
        each e among 0..numExpertos { escribir64(pesos + (ctx * numExpertos + e) * 8, leer64(iniciales + e * 8)) }
    }
    each i among 0..numExpertos * 256 { ef(logExpertos + i * 8, -5.545177444479562) }
    each c among 0..256 { ef(distribucion + c * 8, 0.00390625) }
    escribir64(g, numContextos)
    escribir64(g + 8, numExpertos)
    ef(g + 16, tasa)
    escribir64(g + 24, 0)
    escribir64(g + 32, pesos)
    escribir64(g + 40, logExpertos)
    escribir64(g + 48, distribucion)
    escribir64(g + 56, 0)
    escribir64(g + 64, 0)
    escribir64(g + 72, 0)
    escribir64(g + 80, 0)
    escribir64(g + 88, 0)
    when modo == 1 {
        hold a = ncaReservarAlineado(1024)
        hold b = ncaReservarAlineado(1024)
        hold c = ncaReservarAlineado(1024)
        hold d = ncaReservarAlineado(1024)
        when a == 0 || b == 0 || c == 0 || d == 0 { give 0 }
        each i among 0..128 {
            escribir64(a + i * 8, 0)
            escribir64(b + i * 8, 0)
            escribir64(c + i * 8, 0)
            escribir64(d + i * 8, 0)
        }
        escribir64(g + 56, a)
        escribir64(g + 64, b)
        escribir64(g + 72, c)
        escribir64(g + 80, d)
    }
    give g
}

// probabilidades: dir de 256 Float. lnRapido y maxFloat en línea (mismas
// operaciones y orden que matematica.l).
expose flow mezCargarProbabilidades(g: Int, experto: Int, probabilidades: Int) {
    hold base = leer64(g + 40) + experto * 256 * 8
    each c among 0..256 {
        hold p = floatDeBits(leer64(probabilidades + c * 8))
        change entrada = p
        when !(entrada > 0.000000001) { entrada = 0.000000001 }
        change reducido = entrada
        when !(reducido > 1.0e-30) { reducido = 1.0e-30 }
        change exponente = 0.0
        during reducido < 0.0000152587890625 {
            reducido = reducido * 65536.0
            exponente -= 16.0
        }
        during reducido < 0.5 {
            reducido = reducido * 2.0
            exponente -= 1.0
        }
        during reducido > 2.0 {
            reducido = reducido * 0.5
            exponente += 1.0
        }
        hold z = (reducido - 1.0) / (reducido + 1.0)
        hold z2 = z * z
        hold z4 = z2 * z2
        hold serie = z * (1.0 + z2 / 3.0 + z4 / 5.0 + z4 * z2 / 7.0)
        escribir64(base + c * 8, bitsDeFloat(2.0 * serie + exponente * 0.69314718056))
    }
}

expose flow mezCargarLogits(g: Int, experto: Int, logits: Int, normalizador: Float) {
    hold base = leer64(g + 40) + experto * 256 * 8
    each c among 0..256 {
        escribir64(base + c * 8, bitsDeFloat(floatDeBits(leer64(logits + c * 8)) - normalizador))
    }
}

// Combina los expertos cargados; devuelve el byte más probable. Cada
// z[c] = (0 + w0 l0[c]) + w1 l1[c] + ... se acumula por experto (mismo orden
// de sumas que el bucle por clase).
expose flow mezMezclar(g: Int, contexto: Int) => Int {
    hold numExpertos = leer64(g + 8)
    hold pesos = leer64(g + 32)
    hold logExpertos = leer64(g + 40)
    hold dist = leer64(g + 48)
    escribir64(g + 24, contexto)
    hold basePesos = contexto * numExpertos
    hold finDist = dist + 2048
    change p0 = dist
    during p0 < finDist {
        escribir64(p0, bitsDeFloat(0.0))
        p0 = p0 +% 8
    }
    each e among 0..numExpertos {
        hold w = floatDeBits(leer64(pesos + (basePesos + e) * 8))
        change p = dist
        change q = logExpertos + e * 2048
        during p < finDist {
            escribir64(p, bitsDeFloat(floatDeBits(leer64(p)) + w * floatDeBits(leer64(q))))
            p = p +% 8
            q = q +% 8
        }
    }
    change maximo = -1.0e30
    change mejor = 0
    change pm = dist
    change c = 0
    during pm < finDist {
        hold z = floatDeBits(leer64(pm))
        when z > maximo {
            maximo = z
            mejor = c
        }
        pm = pm +% 8
        c += 1
    }
    change suma = 0.0
    change pe = dist
    during pe < finDist {
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
        escribir64(pe, bitsDeFloat(e))
        suma += e
        pe = pe +% 8
    }
    hold inverso = 1.0 / suma
    change pn = dist
    during pn < finDist {
        escribir64(pn, bitsDeFloat(floatDeBits(leer64(pn)) * inverso))
        pn = pn +% 8
    }
    give mejor
}

expose flow mezAprender(g: Int, byte: Int) {
    hold numExpertos = leer64(g + 8)
    hold pesos = leer64(g + 32)
    hold logExpertos = leer64(g + 40)
    hold dist = leer64(g + 48)
    hold basePesos = leer64(g + 24) * numExpertos
    hold tasa = lf(g + 16)
    each e among 0..numExpertos {
        hold fila = logExpertos + e * 2048
        change esperado = 0.0
        change pd = dist
        change pf = fila
        hold finD = dist + 2048
        during pd < finD {
            esperado += floatDeBits(leer64(pd)) * floatDeBits(leer64(pf))
            pd = pd +% 8
            pf = pf +% 8
        }
        hold gradiente = floatDeBits(leer64(fila + byte * 8)) - esperado
        hold pw = pesos + (basePesos + e) * 8
        ef(pw, clampFloat(floatDeBits(leer64(pw)) + tasa * gradiente, -1.0, 4.0))
    }
}
