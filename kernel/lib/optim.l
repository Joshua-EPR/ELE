// AdamW con calendario de lr (warmup lineal + coseno) y recorte de gradiente
// por norma L2 global.
//
// Registro del optimizador (en el montón, 144 bytes):
//   +0 cantidad  +8 máximo  +16 lista  +24 paso t
//   +32 lr máx  +40 beta1  +48 beta2  +56 eps  +64 weight decay
//   +72 warmup (pasos)  +80 pasos totales  +88 lr mín  +96 norma máx
//   +104 último lr  +112 última norma  +120 beta1^t  +128 beta2^t
// Entrada de la lista (32 bytes): +0 parámetro, +8 m, +16 v, +24 decay (0/1).
// Los Float se guardan como sus bits.

take nucleo.cpu
take nucleo.mem
take mem.monton
take lib.tensor
take lib.matf64

fixed PI = 3.141592653589793

flow fGet(o: Int, desp: Int) => Float { give floatDeBits(leer64(o + desp)) }
flow fSet(o: Int, desp: Int, v: Float) { escribir64(o + desp, bitsDeFloat(v)) }

flow leerElem(dir: Int, tipo: Int) => Float {
    when tipo == F32 { give leerF32(dir) }
    give floatDeBits(leer64(dir))
}

flow escribirElem(dir: Int, tipo: Int, v: Float) {
    when tipo == F32 {
        escribirF32(dir, v)
    } otherwise {
        escribir64(dir, bitsDeFloat(v))
    }
}

// Crea un optimizador para hasta `maximo` parámetros. total = pasos totales
// del calendario; norma_max <= 0 desactiva el recorte.
expose flow optNuevo(maximo: Int, lr: Float, beta1: Float, beta2: Float, eps: Float, decay: Float, warmup: Int, total: Int, lr_min: Float, norma_max: Float) => Int {
    hold o = montonReservar(144)
    hold lista = montonReservar(maximo * 32)
    when o == 0 || lista == 0 { give 0 }
    escribir64(o, 0)
    escribir64(o + 8, maximo)
    escribir64(o + 16, lista)
    escribir64(o + 24, 0)
    fSet(o, 32, lr)
    fSet(o, 40, beta1)
    fSet(o, 48, beta2)
    fSet(o, 56, eps)
    fSet(o, 64, decay)
    escribir64(o + 72, warmup)
    escribir64(o + 80, total)
    fSet(o, 88, lr_min)
    fSet(o, 96, norma_max)
    fSet(o, 104, 0.0)
    fSet(o, 112, 0.0)
    fSet(o, 120, 1.0)
    fSet(o, 128, 1.0)
    give o
}

// Registra un parámetro (con gradiente). `decay`: aplicarle weight decay
// (false para sesgos y ganancias de RMSNorm).
expose flow optAnadir(o: Int, p: Int, decay: Bool) => Bool {
    hold n = leer64(o)
    when n >= leer64(o + 8) || tGrad(p) == 0 { give false }
    hold m = tNuevo(tFilas(p), tColumnas(p), tTipo(p), false)
    hold v = tNuevo(tFilas(p), tColumnas(p), tTipo(p), false)
    when m == 0 || v == 0 { give false }
    hold e = leer64(o + 16) + n * 32
    escribir64(e, p)
    escribir64(e + 8, m)
    escribir64(e + 16, v)
    change flag = 0
    when decay { flag = 1 }
    escribir64(e + 24, flag)
    escribir64(o, n + 1)
    give true
}

// lr del paso t (1, 2, ...): warmup lineal y luego coseno hasta lr_min.
expose flow optLrEn(o: Int, t: Int) => Float {
    hold lr_max = fGet(o, 32)
    hold lr_min = fGet(o, 88)
    hold warmup = leer64(o + 72)
    hold total = leer64(o + 80)
    when warmup > 0 && t <= warmup { give lr_max * Float(t) / Float(warmup) }
    when t >= total { give lr_min }
    hold progreso = Float(t - warmup) / Float(total - warmup)
    give lr_min + 0.5 * (lr_max - lr_min) * (1.0 + cosF(PI * progreso))
}

expose flow optUltimoLr(o: Int) => Float { give fGet(o, 104) }
expose flow optUltimaNorma(o: Int) => Float { give fGet(o, 112) }
expose flow optPasos(o: Int) => Int { give leer64(o + 24) }

// Pone a cero los gradientes de todos los parámetros.
expose flow optCeros(o: Int) {
    hold lista = leer64(o + 16)
    each k among 0..leer64(o) { tCerosGrad(leer64(lista + k * 32)) }
}

// Un paso: recorta por norma global, actualiza m, v y los parámetros.
// Devuelve la norma del gradiente (antes del recorte); el lr usado queda en
// optUltimoLr. No pone a cero los gradientes.
expose flow optPaso(o: Int) => Float {
    hold lista = leer64(o + 16)
    hold n = leer64(o)
    // Norma L2 global, en orden fijo.
    change suma = 0.0
    each k among 0..n {
        hold g = tGrad(leer64(lista + k * 32))
        hold tipo = tTipo(g)
        each i among 0..tFilas(g) {
            hold fila = tDir(g, i, 0)
            each j among 0..tColumnas(g) {
                hold x = leerElem(fila + j * tipo, tipo)
                suma = suma + x * x
            }
        }
    }
    hold norma = raizF64(suma)
    change escala = 1.0
    hold maxima = fGet(o, 96)
    when maxima > 0.0 && norma > maxima { escala = maxima / (norma + 0.000001) }

    hold t = leer64(o + 24) + 1
    escribir64(o + 24, t)
    hold lr = optLrEn(o, t)
    fSet(o, 104, lr)
    fSet(o, 112, norma)
    hold beta1 = fGet(o, 40)
    hold beta2 = fGet(o, 48)
    hold eps = fGet(o, 56)
    hold decay = fGet(o, 64)
    hold b1t = fGet(o, 120) * beta1
    hold b2t = fGet(o, 128) * beta2
    fSet(o, 120, b1t)
    fSet(o, 128, b2t)
    hold corr1 = 1.0 - b1t
    hold corr2 = 1.0 - b2t
    each k among 0..n {
        hold e = lista + k * 32
        hold p = leer64(e)
        hold m = leer64(e + 8)
        hold v = leer64(e + 16)
        change dec = 0.0
        when leer64(e + 24) != 0 { dec = decay }
        hold g = tGrad(p)
        hold tipo = tTipo(p)
        each i among 0..tFilas(p) {
            hold fp = tDir(p, i, 0)
            hold fg = tDir(g, i, 0)
            hold fm = tDir(m, i, 0)
            hold fv = tDir(v, i, 0)
            each j among 0..tColumnas(p) {
                hold d = j * tipo
                hold grad = leerElem(fg + d, tipo) * escala
                hold mm = beta1 * leerElem(fm + d, tipo) + (1.0 - beta1) * grad
                hold vv = beta2 * leerElem(fv + d, tipo) + (1.0 - beta2) * grad * grad
                escribirElem(fm + d, tipo, mm)
                escribirElem(fv + d, tipo, vv)
                hold w = leerElem(fp + d, tipo)
                hold paso = (mm / corr1) / (raizF64(vv / corr2) + eps)
                escribirElem(fp + d, tipo, w * (1.0 - lr * dec) - lr * paso)
            }
        }
    }
    give norma
}
