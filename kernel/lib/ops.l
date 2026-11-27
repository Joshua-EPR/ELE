// Operaciones de la red con su forward y su backward.
//
// Convención: forward(entradas..., salida). backward recibe los mismos
// tensores; el gradiente de la salida está en tGrad(salida) y cada
// backward SUMA (+=) a los gradientes de sus entradas que existan.
// Todas las sumas de reducción se hacen en orden fijo y en Float (f64):
// los resultados son deterministas.

take nucleo.mem
take lib.tensor
take lib.matf64
take lib.sgemm

fixed RAIZ_2_PI = 0.7978845608028654
fixed GELU_C = 0.044715
fixed EPS_RMS = 0.00001
expose fixed MASCARA = -1000000000.0

// ---- multiplicación de matrices --------------------------------------------

// Camino rápido: f32, columnas múltiplo de 16 y datos contiguos.
flow rapido(a: Int, b: Int, c: Int) => Bool {
    when tTipo(a) != F32 || tTipo(b) != F32 || tTipo(c) != F32 { give false }
    give tColumnas(c) % 16 == 0
}

// c (+)= op(a) · op(b) con escalares; ta/tb = transpuesta.
flow matmulEscalar(a: Int, ta: Bool, b: Int, tb: Bool, c: Int, acumular: Bool) {
    hold m = tFilas(c)
    hold n = tColumnas(c)
    change k_total = tColumnas(a)
    when ta { k_total = tFilas(a) }
    each i among 0..m {
        each j among 0..n {
            change s = 0.0
            when acumular { s = tLeer(c, i, j) }
            each k among 0..k_total {
                change x = 0.0
                when ta { x = tLeer(a, k, i) } otherwise { x = tLeer(a, i, k) }
                change y = 0.0
                when tb { y = tLeer(b, j, k) } otherwise { y = tLeer(b, k, j) }
                s = s + x * y
            }
            tEscribir(c, i, j, s)
        }
    }
}

flow matmulGeneral(a: Int, ta: Bool, b: Int, tb: Bool, c: Int, acumular: Bool, nucleos: Int) {
    change k_total = tColumnas(a)
    when ta { k_total = tFilas(a) }
    when rapido(a, b, c) {
        hold bien = sgemm(tFilas(c), tColumnas(c), k_total, tDatos(a), tPaso(a), ta, tDatos(b), tPaso(b), tb, tDatos(c), tPaso(c), acumular, SGEMM_3x16_MEMORIA, nucleos)
        when bien { give }
    }
    matmulEscalar(a, ta, b, tb, c, acumular)
}

// c = a · b.
expose flow opMatmul(a: Int, b: Int, c: Int, nucleos: Int) {
    matmulGeneral(a, false, b, false, c, false, nucleos)
}

// da += dc · bᵀ ; db += aᵀ · dc.
expose flow opMatmulAtras(a: Int, b: Int, c: Int, nucleos: Int) {
    hold dc = tGrad(c)
    when tGrad(a) != 0 { matmulGeneral(dc, false, b, true, tGrad(a), true, nucleos) }
    when tGrad(b) != 0 { matmulGeneral(a, true, dc, false, tGrad(b), true, nucleos) }
}

// ---- elemento a elemento -----------------------------------------------------

// y = a + b, con b de una fila (sesgo) difundida a todas las filas, o del
// mismo tamaño que a.
expose flow opSumar(a: Int, b: Int, y: Int) {
    hold fila_b = tFilas(b) == 1
    each i among 0..tFilas(y) {
        each j among 0..tColumnas(y) {
            change bi = i
            when fila_b { bi = 0 }
            tEscribir(y, i, j, tLeer(a, i, j) + tLeer(b, bi, j))
        }
    }
}

expose flow opSumarAtras(a: Int, b: Int, y: Int) {
    hold dy = tGrad(y)
    hold fila_b = tFilas(b) == 1
    each i among 0..tFilas(y) {
        each j among 0..tColumnas(y) {
            hold g = tLeer(dy, i, j)
            when tGrad(a) != 0 { tSumar(tGrad(a), i, j, g) }
            when tGrad(b) != 0 && !fila_b { tSumar(tGrad(b), i, j, g) }
        }
    }
    when tGrad(b) != 0 && fila_b {
        each j among 0..tColumnas(y) {
            change s = 0.0
            each i among 0..tFilas(y) { s = s + tLeer(dy, i, j) }
            tSumar(tGrad(b), 0, j, s)
        }
    }
}

// y = a ⊙ b (mismo tamaño).
expose flow opMultiplicar(a: Int, b: Int, y: Int) {
    each i among 0..tFilas(y) {
        each j among 0..tColumnas(y) { tEscribir(y, i, j, tLeer(a, i, j) * tLeer(b, i, j)) }
    }
}

expose flow opMultiplicarAtras(a: Int, b: Int, y: Int) {
    hold dy = tGrad(y)
    each i among 0..tFilas(y) {
        each j among 0..tColumnas(y) {
            hold g = tLeer(dy, i, j)
            when tGrad(a) != 0 { tSumar(tGrad(a), i, j, g * tLeer(b, i, j)) }
            when tGrad(b) != 0 { tSumar(tGrad(b), i, j, g * tLeer(a, i, j)) }
        }
    }
}

// ---- embedding ---------------------------------------------------------------

// y[i] = tabla[ids[i]] (ids: n enteros de 64 bits en memoria).
expose flow opEmbedding(tabla: Int, ids: Int, y: Int) {
    each i among 0..tFilas(y) {
        hold fila = leer64(ids + i * 8)
        each j among 0..tColumnas(y) { tEscribir(y, i, j, tLeer(tabla, fila, j)) }
    }
}

expose flow opEmbeddingAtras(tabla: Int, ids: Int, y: Int) {
    when tGrad(tabla) == 0 { give }
    each i among 0..tFilas(y) {
        hold fila = leer64(ids + i * 8)
        each j among 0..tColumnas(y) { tSumar(tGrad(tabla), fila, j, tLeer(tGrad(y), i, j)) }
    }
}

// ---- máscara causal y softmax --------------------------------------------------

// y = x con y[i][j] = MASCARA para j > i (atención causal).
expose flow opMascaraCausal(x: Int, y: Int) {
    each i among 0..tFilas(y) {
        each j among 0..tColumnas(y) {
            when j > i { tEscribir(y, i, j, MASCARA) } otherwise { tEscribir(y, i, j, tLeer(x, i, j)) }
        }
    }
}

expose flow opMascaraCausalAtras(x: Int, y: Int) {
    when tGrad(x) == 0 { give }
    each i among 0..tFilas(y) {
        each j among 0..(i + 1) {
            when j < tColumnas(y) { tSumar(tGrad(x), i, j, tLeer(tGrad(y), i, j)) }
        }
    }
}

// Softmax por filas, estable: se resta el máximo antes de exp.
expose flow opSoftmax(x: Int, y: Int) {
    hold n = tColumnas(x)
    each i among 0..tFilas(x) {
        change maximo = tLeer(x, i, 0)
        each j among 1..n {
            hold v = tLeer(x, i, j)
            when v > maximo { maximo = v }
        }
        change suma = 0.0
        each j among 0..n {
            hold e = expF(tLeer(x, i, j) - maximo)
            tEscribir(y, i, j, e)
            suma = suma + e
        }
        each j among 0..n { tEscribir(y, i, j, tLeer(y, i, j) / suma) }
    }
}

// dx = y ⊙ (dy - Σ dy·y) por fila.
expose flow opSoftmaxAtras(x: Int, y: Int) {
    when tGrad(x) == 0 { give }
    hold dy = tGrad(y)
    hold n = tColumnas(x)
    each i among 0..tFilas(x) {
        change punto = 0.0
        each j among 0..n { punto = punto + tLeer(dy, i, j) * tLeer(y, i, j) }
        each j among 0..n {
            tSumar(tGrad(x), i, j, tLeer(y, i, j) * (tLeer(dy, i, j) - punto))
        }
    }
}

// ---- RMSNorm -------------------------------------------------------------------

// y = x / rms(x) ⊙ g, con rms = sqrt(media(x²) + eps) por fila; g: 1 x n.
expose flow opRmsNorm(x: Int, g: Int, y: Int) {
    hold n = tColumnas(x)
    each i among 0..tFilas(x) {
        change s = 0.0
        each j among 0..n {
            hold v = tLeer(x, i, j)
            s = s + v * v
        }
        hold r = raizF64(s / Float(n) + EPS_RMS)
        each j among 0..n { tEscribir(y, i, j, tLeer(x, i, j) / r * tLeer(g, 0, j)) }
    }
}

// dx_j = (g_j dy_j)/r - x_j/(n r³) Σ_k g_k dy_k x_k ; dg_j += Σ_i dy_ij x_ij / r_i.
expose flow opRmsNormAtras(x: Int, g: Int, y: Int) {
    hold dy = tGrad(y)
    hold n = tColumnas(x)
    each i among 0..tFilas(x) {
        change s = 0.0
        each j among 0..n {
            hold v = tLeer(x, i, j)
            s = s + v * v
        }
        hold r = raizF64(s / Float(n) + EPS_RMS)
        change punto = 0.0
        each k among 0..n { punto = punto + tLeer(g, 0, k) * tLeer(dy, i, k) * tLeer(x, i, k) }
        each j among 0..n {
            hold xv = tLeer(x, i, j)
            when tGrad(x) != 0 {
                tSumar(tGrad(x), i, j, tLeer(g, 0, j) * tLeer(dy, i, j) / r - xv * punto / (Float(n) * r * r * r))
            }
            when tGrad(g) != 0 { tSumar(tGrad(g), 0, j, tLeer(dy, i, j) * xv / r) }
        }
    }
}

// ---- GELU (aproximación tanh) ------------------------------------------------

flow geluF(x: Float) => Float {
    give 0.5 * x * (1.0 + tanhF(RAIZ_2_PI * (x + GELU_C * x * x * x)))
}

flow geluDerivada(x: Float) => Float {
    hold u = RAIZ_2_PI * (x + GELU_C * x * x * x)
    hold t = tanhF(u)
    hold du = RAIZ_2_PI * (1.0 + 3.0 * GELU_C * x * x)
    give 0.5 * (1.0 + t) + 0.5 * x * (1.0 - t * t) * du
}

expose flow opGelu(x: Int, y: Int) {
    each i among 0..tFilas(x) {
        each j among 0..tColumnas(x) { tEscribir(y, i, j, geluF(tLeer(x, i, j))) }
    }
}

expose flow opGeluAtras(x: Int, y: Int) {
    when tGrad(x) == 0 { give }
    each i among 0..tFilas(x) {
        each j among 0..tColumnas(x) {
            tSumar(tGrad(x), i, j, tLeer(tGrad(y), i, j) * geluDerivada(tLeer(x, i, j)))
        }
    }
}

// ---- entropía cruzada ----------------------------------------------------------

// Pérdida media de -log softmax(logits)[objetivo] sobre las filas.
// objetivos: n enteros de 64 bits. Si `atras`, suma a tGrad(logits)
// (softmax - onehot) / filas (por `escala`).
expose flow opEntropiaCruzada(logits: Int, objetivos: Int, atras: Bool, escala: Float) => Float {
    hold filas = tFilas(logits)
    hold n = tColumnas(logits)
    change total = 0.0
    each i among 0..filas {
        change maximo = tLeer(logits, i, 0)
        each j among 1..n {
            hold v = tLeer(logits, i, j)
            when v > maximo { maximo = v }
        }
        change suma = 0.0
        each j among 0..n { suma = suma + expF(tLeer(logits, i, j) - maximo) }
        hold objetivo = leer64(objetivos + i * 8)
        hold log_z = maximo + logF(suma)
        total = total + log_z - tLeer(logits, i, objetivo)
        when atras && tGrad(logits) != 0 {
            each j among 0..n {
                change p = expF(tLeer(logits, i, j) - log_z)
                when j == objetivo { p = p - 1.0 }
                tSumar(tGrad(logits), i, j, p * escala / Float(filas))
            }
        }
    }
    give total / Float(filas)
}
