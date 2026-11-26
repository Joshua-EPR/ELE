// ENCA: mezclador geométrico (producto de expertos) con pesos aprendidos por
// contexto, port literal de mezclador_geometrico.l.
//   log p(c) = sum_e w[ctx, e] * log p_e(c) - log Z
//
// Bloque (56 bytes):
//   +0 numContextos  +8 numExpertos  +16 tasa(F)  +24 contexto
//   +32 pesos(F, numContextos*numExpertos)  +40 logExpertos(F, numExpertos*256)
//   +48 distribucion(F, 256)

take nucleo.cpu
take nucleo.mem
take enca.matematica

// iniciales: dir de numExpertos Float.
expose flow mezCrear(numContextos: Int, numExpertos: Int, tasa: Float, iniciales: Int) => Int {
    hold g = ncaReservar(56)
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
    give g
}

// probabilidades: dir de 256 Float.
expose flow mezCargarProbabilidades(g: Int, experto: Int, probabilidades: Int) {
    hold base = leer64(g + 40) + experto * 256 * 8
    each c among 0..256 {
        ef(base + c * 8, lnRapido(maxFloat(lf(probabilidades + c * 8), 0.000000001)))
    }
}

expose flow mezCargarLogits(g: Int, experto: Int, logits: Int, normalizador: Float) {
    hold base = leer64(g + 40) + experto * 256 * 8
    each c among 0..256 {
        ef(base + c * 8, lf(logits + c * 8) - normalizador)
    }
}

// Combina los expertos cargados; devuelve el byte más probable.
expose flow mezMezclar(g: Int, contexto: Int) => Int {
    hold numExpertos = leer64(g + 8)
    hold pesos = leer64(g + 32)
    hold logExpertos = leer64(g + 40)
    hold dist = leer64(g + 48)
    escribir64(g + 24, contexto)
    hold basePesos = contexto * numExpertos
    change maximo = -1.0e30
    change mejor = 0
    each c among 0..256 {
        change z = 0.0
        each e among 0..numExpertos {
            z += lf(pesos + (basePesos + e) * 8) * lf(logExpertos + (e * 256 + c) * 8)
        }
        ef(dist + c * 8, z)
        when z > maximo {
            maximo = z
            mejor = c
        }
    }
    change suma = 0.0
    each c among 0..256 {
        hold valor = expFloat(lf(dist + c * 8) - maximo)
        ef(dist + c * 8, valor)
        suma += valor
    }
    hold inverso = 1.0 / suma
    each c among 0..256 {
        ef(dist + c * 8, lf(dist + c * 8) * inverso)
    }
    give mejor
}

expose flow mezAprender(g: Int, byte: Int) {
    hold numExpertos = leer64(g + 8)
    hold pesos = leer64(g + 32)
    hold logExpertos = leer64(g + 40)
    hold dist = leer64(g + 48)
    hold basePesos = leer64(g + 24) * numExpertos
    each e among 0..numExpertos {
        hold base = e * 256
        change esperado = 0.0
        each c among 0..256 {
            esperado += lf(dist + c * 8) * lf(logExpertos + (base + c) * 8)
        }
        hold gradiente = lf(logExpertos + (base + byte) * 8) - esperado
        ef(pesos + (basePesos + e) * 8, clampFloat(lf(pesos + (basePesos + e) * 8) + lf(g + 16) * gradiente, -1.0, 4.0))
    }
}
