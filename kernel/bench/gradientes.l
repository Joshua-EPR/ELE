// Verificación de gradientes (hito 15): para cada operación se compara el
// backward con diferencias finitas centradas en f64,
//   dL/dx ≈ (L(x + h) - L(x - h)) / 2h,  h = 1e-6,
// con L = Σ W ⊙ y para pesos W aleatorios fijos (la entropía cruzada ya es
// un escalar). Se recorre cada elemento de cada entrada y se informa el
// error relativo máximo |a - n| / max(|a|, |n|, 1e-8).

take nucleo.mem
take lib.consola
take lib.tensor
take lib.ops
take lib.matf64
take lib.aleatorio

fixed H = 0.000001
fixed UMBRAL = 0.00001

expose fixed OP_MATMUL = 1
expose fixed OP_SUMAR = 2
expose fixed OP_MULTIPLICAR = 3
expose fixed OP_EMBEDDING = 4
expose fixed OP_MASCARA = 5
expose fixed OP_SOFTMAX = 6
expose fixed OP_RMSNORM = 7
expose fixed OP_GELU = 8
expose fixed OP_ENTROPIA = 9
expose fixed OP_MATMUL_F32 = 10

// Caso: +0 entrada a, +8 entrada b (o 0), +16 salida y, +24 pesos W,
// +32 ids/objetivos (enteros), +40 generador, +48 operación,
// +56 copia f64 de a, +64 copia f64 de b (solo OP_MATMUL_F32),
// +72 intermedio de máscara -> softmax (OP_MASCARA).
flow caso() => Int { give reservar(80, 8) }
flow generador() => Int { give reservar(16, 8) }

flow llenar(t: Int, g: Int) {
    each i among 0..tFilas(t) {
        each j among 0..tColumnas(t) { tEscribir(t, i, j, pcgEntre(g, -1.5, 1.5)) }
    }
}

flow adelante(c: Int) {
    hold op = leer64(c + 48)
    hold a = leer64(c)
    hold b = leer64(c + 8)
    hold y = leer64(c + 16)
    when op == OP_MATMUL || op == OP_MATMUL_F32 { opMatmul(a, b, y, 1) }
    when op == OP_SUMAR { opSumar(a, b, y) }
    when op == OP_MULTIPLICAR { opMultiplicar(a, b, y) }
    when op == OP_EMBEDDING { opEmbedding(a, leer64(c + 32), y) }
    // La máscara se prueba como se usa: softmax(máscara(x)). Sola, L sumaría
    // W·(-1e9) y la diferencia finita perdería toda la precisión.
    when op == OP_MASCARA {
        opMascaraCausal(a, leer64(c + 72))
        opSoftmax(leer64(c + 72), y)
    }
    when op == OP_SOFTMAX { opSoftmax(a, y) }
    when op == OP_RMSNORM { opRmsNorm(a, b, y) }
    when op == OP_GELU { opGelu(a, y) }
}

flow atras(c: Int) {
    hold op = leer64(c + 48)
    hold a = leer64(c)
    hold b = leer64(c + 8)
    hold y = leer64(c + 16)
    when op == OP_MATMUL || op == OP_MATMUL_F32 { opMatmulAtras(a, b, y, 1) }
    when op == OP_SUMAR { opSumarAtras(a, b, y) }
    when op == OP_MULTIPLICAR { opMultiplicarAtras(a, b, y) }
    when op == OP_EMBEDDING { opEmbeddingAtras(a, leer64(c + 32), y) }
    when op == OP_MASCARA {
        opSoftmaxAtras(leer64(c + 72), y)
        opMascaraCausalAtras(a, leer64(c + 72))
    }
    when op == OP_SOFTMAX { opSoftmaxAtras(a, y) }
    when op == OP_RMSNORM { opRmsNormAtras(a, b, y) }
    when op == OP_GELU { opGeluAtras(a, y) }
}

// L en f64. Para OP_MATMUL_F32 se usa el producto escalar en f64 de las
// copias f64 (la referencia), no el SGEMM.
flow perdida(c: Int) => Float {
    hold op = leer64(c + 48)
    when op == OP_ENTROPIA { give opEntropiaCruzada(leer64(c), leer64(c + 32), false, 1.0) }
    hold w = leer64(c + 24)
    when op == OP_MATMUL_F32 {
        hold a = leer64(c + 56)
        hold b = leer64(c + 64)
        change total = 0.0
        each i among 0..tFilas(w) {
            each j among 0..tColumnas(w) {
                change s = 0.0
                each k among 0..tColumnas(a) { s = s + tLeer(a, i, k) * tLeer(b, k, j) }
                total = total + s * tLeer(w, i, j)
            }
        }
        give total
    }
    adelante(c)
    hold y = leer64(c + 16)
    change total = 0.0
    each i among 0..tFilas(y) {
        each j among 0..tColumnas(y) { total = total + tLeer(w, i, j) * tLeer(y, i, j) }
    }
    give total
}

// Error relativo máximo de los gradientes de la entrada `t` (con su copia
// f64 `ref` para OP_MATMUL_F32, o la misma `t`).
flow compararEntrada(c: Int, t: Int, ref: Int) => Float {
    change peor = 0.0
    each i among 0..tFilas(t) {
        each j among 0..tColumnas(t) {
            hold original = tLeer(ref, i, j)
            tEscribir(ref, i, j, original + H)
            hold mas = perdida(c)
            tEscribir(ref, i, j, original - H)
            hold menos = perdida(c)
            tEscribir(ref, i, j, original)
            hold numerico = (mas - menos) / (2.0 * H)
            hold analitico = tLeer(tGrad(t), i, j)
            change escala = absF(analitico)
            when absF(numerico) > escala { escala = absF(numerico) }
            when escala < 0.00000001 { escala = 0.00000001 }
            hold error = absF(analitico - numerico) / escala
            when error > peor { peor = error }
        }
    }
    give peor
}

flow probar(nombre: Int, op: Int, filas_a: Int, cols_a: Int, filas_b: Int, cols_b: Int, filas_y: Int, cols_y: Int) => Bool {
    hold marca = arenaMarca()
    hold c = caso()
    hold g = generador()
    pcgSembrar(g, 1234 + op, op)
    change tipo = F64
    when op == OP_MATMUL_F32 { tipo = F32 }
    hold a = tNuevo(filas_a, cols_a, tipo, true)
    llenar(a, g)
    change b = 0
    when filas_b > 0 {
        b = tNuevo(filas_b, cols_b, tipo, true)
        llenar(b, g)
    }
    hold y = tNuevo(filas_y, cols_y, tipo, true)
    hold w = tNuevo(filas_y, cols_y, F64, false)
    llenar(w, g)
    hold ids = arenaReservar(8 * 64)
    each i among 0..64 {
        change limite = filas_a
        when op == OP_ENTROPIA { limite = cols_a }
        escribir64(ids + i * 8, pcgEntero(g, limite))
    }
    escribir64(c, a)
    escribir64(c + 8, b)
    escribir64(c + 16, y)
    escribir64(c + 24, w)
    escribir64(c + 32, ids)
    escribir64(c + 48, op)
    escribir64(c + 72, tNuevo(filas_y, cols_y, tipo, true))
    // Analítico.
    change error = 0.0
    when op == OP_ENTROPIA {
        hold perdida_analitica = opEntropiaCruzada(a, ids, true, 1.0)
        error = compararEntrada(c, a, a)
    } otherwise {
        adelante(c)
        tCopiar(w, tGrad(y))
        atras(c)
        when op == OP_MATMUL_F32 {
            hold a64 = tNuevo(filas_a, cols_a, F64, false)
            hold b64 = tNuevo(filas_b, cols_b, F64, false)
            tCopiar(a, a64)
            tCopiar(b, b64)
            escribir64(c + 56, a64)
            escribir64(c + 64, b64)
            error = compararEntrada(c, a, a64)
            hold error_b = compararEntrada(c, b, b64)
            when error_b > error { error = error_b }
        } otherwise {
            error = compararEntrada(c, a, a)
            when b != 0 && op != OP_EMBEDDING {
                hold error_b = compararEntrada(c, b, b)
                when error_b > error { error = error_b }
            }
        }
    }
    // El SGEMM en f32 contra la referencia f64: tolera el redondeo f32.
    change umbral = UMBRAL
    when op == OP_MATMUL_F32 { umbral = 0.001 }
    kprint(cadena("  "))
    kprint(nombre)
    kprint(cadena(": error relativo máximo "))
    kprintCientifico(error, 2)
    hold bien = error < umbral
    when bien { kprintln(cadena(" OK")) } otherwise { kprintln(cadena(" FALLÓ")) }
    arenaVolver(marca)
    give bien
}

expose flow gradientesVerificar() => Bool {
    kprintln(cadena("verificación de gradientes (diferencias finitas en f64, h = 1e-6):"))
    change todo = true
    todo = probar(cadena("matmul        "), OP_MATMUL, 3, 5, 5, 4, 3, 4) && todo
    todo = probar(cadena("matmul f32/SGEMM"), OP_MATMUL_F32, 16, 32, 32, 16, 16, 16) && todo
    todo = probar(cadena("suma con sesgo "), OP_SUMAR, 3, 4, 1, 4, 3, 4) && todo
    todo = probar(cadena("multiplicación"), OP_MULTIPLICAR, 3, 4, 3, 4, 3, 4) && todo
    todo = probar(cadena("embedding     "), OP_EMBEDDING, 6, 4, 0, 0, 5, 4) && todo
    todo = probar(cadena("máscara+softmax"), OP_MASCARA, 4, 4, 0, 0, 4, 4) && todo
    todo = probar(cadena("softmax       "), OP_SOFTMAX, 3, 5, 0, 0, 3, 5) && todo
    todo = probar(cadena("RMSNorm       "), OP_RMSNORM, 3, 6, 1, 6, 3, 6) && todo
    todo = probar(cadena("GELU          "), OP_GELU, 3, 4, 0, 0, 3, 4) && todo
    todo = probar(cadena("entropía cruz."), OP_ENTROPIA, 4, 6, 0, 0, 4, 6) && todo
    give todo
}
