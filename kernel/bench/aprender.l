// Primer aprendizaje (hito 16): un MLP aprende XOR y dos círculos
// concéntricos, y un modelo de bigramas por bytes aprende texto.txt hasta
// acercarse a la entropía real de bigramas. Todo con AdamW (lib/optim.l) y
// un log de entrenamiento en pantalla y en ENTRENA.LOG (FAT32).

take nucleo.cpu
take nucleo.mem
take mem.monton
take lib.consola
take lib.tensor
take lib.ops
take lib.matf64
take lib.aleatorio
take lib.optim
take dispositivos.apic
take almacenamiento.disco
take almacenamiento.fat32

fixed PI = 3.141592653589793
fixed CAPACIDAD_LOG = 262144

// Bigramas: lote, pasos, calendario.
fixed BG_LOTE = 256
fixed BG_PASOS = 1500
fixed BG_WARMUP = 50
fixed BG_CADA = 150

// ---- log: pantalla + ENTRENA.LOG ------------------------------------------------
// Estado: +0 búfer de sector, +8 bytes en el búfer, +16 desplazamiento en el
// archivo, +24 capacidad, +32 archivo activo (0/1), +40 desbordado (0/1).
flow logReg() => Int { give reservar(48, 8) }

// Crea ENTRENA.LOG con capacidad fija. Sin FAT32 el log queda solo en pantalla.
flow logAbrir() {
    hold e = logReg()
    escribir64(e + 32, 0)
    escribir64(e + 8, 0)
    escribir64(e + 16, 0)
    escribir64(e + 24, CAPACIDAD_LOG)
    escribir64(e + 40, 0)
    when !discoHayPermitida() || !fatMontar() { give }
    hold buf = montonReservar(512)
    when buf == 0 { give }
    each k among 0..64 { escribir64(buf + k * 8, 0) }
    escribir64(e, buf)
    when fatCrear(cadena("ENTRENA LOG"), cadena("ENTRENA.LOG"), CAPACIDAD_LOG) {
        escribir64(e + 32, 1)
    }
}

flow logVaciarSector() {
    hold e = logReg()
    hold buf = leer64(e)
    hold desp = leer64(e + 16)
    when desp + 512 <= leer64(e + 24) {
        when !fatEscribir(desp, 512, buf) { escribir64(e + 40, 1) }
    } otherwise {
        escribir64(e + 40, 1)
    }
    escribir64(e + 16, desp + 512)
    escribir64(e + 8, 0)
    each k among 0..64 { escribir64(buf + k * 8, 0) }
}

flow logByte(b: Int) {
    kprintByte(b)
    hold e = logReg()
    when leer64(e + 32) != 1 { give }
    hold n = leer64(e + 8)
    escribir8(leer64(e) + n, b)
    escribir64(e + 8, n + 1)
    when n + 1 == 512 { logVaciarSector() }
}

flow logTexto(t: Int) {
    each i among 0..leer64(t) { logByte(leer8(t + 8 + i)) }
}

flow logEntero(v: Int) {
    hold b = reservar(32, 8)
    hold n = fmtEntero(v, b)
    each i among 0..n { logByte(leer8(b + i)) }
}

flow logDecimal(x: Float, dec: Int) {
    hold b = reservar(48, 8)
    hold n = fmtDecimal(x, dec, b)
    each i among 0..n { logByte(leer8(b + i)) }
}

// Termina el log: escribe el último sector y deja el tamaño real en la
// entrada de directorio (fatCrear reutiliza los clusters).
flow logCerrar() => Bool {
    hold e = logReg()
    when leer64(e + 32) != 1 { give true }
    escribir64(e + 32, 0)
    change real = leer64(e + 16) + leer64(e + 8)
    when leer64(e + 8) > 0 {
        escribir64(e + 32, 1)
        logVaciarSector()
        escribir64(e + 32, 0)
    }
    when real > leer64(e + 24) { real = leer64(e + 24) }
    hold bien = fatCrear(cadena("ENTRENA LOG"), cadena("ENTRENA.LOG"), real) && leer64(e + 40) == 0
    give discoVaciar() && bien
}

flow uno(v: Int) => Int {
    when v < 1 { give 1 }
    give v
}

// Línea del log: paso, pérdida, lr, norma del gradiente, ms por paso, pares/s.
flow logLinea(paso: Int, perdida: Float, lr: Float, norma: Float, ms: Float, tasa: Int) {
    logTexto(cadena("paso "))
    logEntero(paso)
    logTexto(cadena(" perdida "))
    logDecimal(perdida, 4)
    logTexto(cadena(" lr "))
    logDecimal(lr, 5)
    logTexto(cadena(" norma "))
    logDecimal(norma, 4)
    logTexto(cadena(" ms/paso "))
    logDecimal(ms, 3)
    logTexto(cadena(" pares/s "))
    logEntero(tasa)
    logByte(10)
}

// Milisegundos por paso en un intervalo de `pasos` pasos y `ciclos` ciclos.
flow msPorPaso(ciclos: Int, pasos: Int) => Float {
    hold cpm = uno(tscCiclosPorMs())
    give Float(ciclos) / Float(cpm) / Float(uno(pasos))
}

flow paresPorSegundo(lote: Int, ms: Float) => Int {
    when ms <= 0.0 { give 0 }
    give Int(Float(lote) * 1000.0 / ms)
}

// ---- MLP: Linear -> GELU -> Linear ------------------------------------------------
// +0 W1  +8 b1  +16 W2  +24 b2  +32 x  +40 z1  +48 a1  +56 h  +64 z2  +72 logits
flow mlpNuevo(n: Int, ent: Int, oc: Int, cl: Int, base: Int, g: Int) => Int {
    hold m = montonReservar(80)
    when base == 0 {
        hold a1 = 1.5 / raizF64(Float(ent))
        hold a2 = 1.5 / raizF64(Float(oc))
        hold w1 = tNuevo(ent, oc, F32, true)
        hold w2 = tNuevo(oc, cl, F32, true)
        each i among 0..ent {
            each j among 0..oc { tEscribir(w1, i, j, pcgEntre(g, 0.0 - a1, a1)) }
        }
        each i among 0..oc {
            each j among 0..cl { tEscribir(w2, i, j, pcgEntre(g, 0.0 - a2, a2)) }
        }
        escribir64(m, w1)
        escribir64(m + 8, tNuevo(1, oc, F32, true))
        escribir64(m + 16, w2)
        escribir64(m + 24, tNuevo(1, cl, F32, true))
    } otherwise {
        each k among 0..4 { escribir64(m + k * 8, leer64(base + k * 8)) }
    }
    escribir64(m + 32, tNuevo(n, ent, F32, false))
    escribir64(m + 40, tNuevo(n, oc, F32, true))
    escribir64(m + 48, tNuevo(n, oc, F32, true))
    escribir64(m + 56, tNuevo(n, oc, F32, true))
    escribir64(m + 64, tNuevo(n, cl, F32, true))
    escribir64(m + 72, tNuevo(n, cl, F32, true))
    give m
}

flow mlpAdelante(m: Int) {
    opMatmul(leer64(m + 32), leer64(m), leer64(m + 40), 1)
    opSumar(leer64(m + 40), leer64(m + 8), leer64(m + 48))
    opGelu(leer64(m + 48), leer64(m + 56))
    opMatmul(leer64(m + 56), leer64(m + 16), leer64(m + 64), 1)
    opSumar(leer64(m + 64), leer64(m + 24), leer64(m + 72))
}

// Backward: el gradiente de los logits ya está sembrado (entropía cruzada).
flow mlpAtras(m: Int) {
    opSumarAtras(leer64(m + 64), leer64(m + 24), leer64(m + 72))
    opMatmulAtras(leer64(m + 56), leer64(m + 16), leer64(m + 64), 1)
    opGeluAtras(leer64(m + 48), leer64(m + 56))
    opSumarAtras(leer64(m + 40), leer64(m + 8), leer64(m + 48))
    opMatmulAtras(leer64(m + 32), leer64(m), leer64(m + 40), 1)
}

flow mlpCerosAct(m: Int) {
    each k among 5..10 { tCerosGrad(leer64(m + k * 8)) }
}

// Registra W1, b1, W2, b2 (decay solo en las matrices, no en los sesgos).
flow mlpRegistrar(opt: Int, m: Int) {
    optAnadir(opt, leer64(m), true)
    optAnadir(opt, leer64(m + 8), false)
    optAnadir(opt, leer64(m + 16), true)
    optAnadir(opt, leer64(m + 24), false)
}

// Aciertos (argmax de los logits == objetivo) tras un adelante.
flow mlpAciertos(m: Int, tgt: Int) => Int {
    hold lg = leer64(m + 72)
    change bien = 0
    each i among 0..tFilas(lg) {
        change mejor = 0
        each j among 1..tColumnas(lg) {
            when tLeer(lg, i, j) > tLeer(lg, i, mejor) { mejor = j }
        }
        when mejor == leer64(tgt + i * 8) { bien += 1 }
    }
    give bien
}

flow mlpEntrenar(m: Int, opt: Int, tgt: Int, pasos: Int, cada: Int) {
    hold n = tFilas(leer64(m + 32))
    hold fin = pasos + 1
    change t0 = rdtsc()
    change ultimo = 0
    each paso among 1..fin {
        optCeros(opt)
        mlpCerosAct(m)
        mlpAdelante(m)
        hold perdida = opEntropiaCruzada(leer64(m + 72), tgt, true, 1.0)
        mlpAtras(m)
        hold norma = optPaso(opt)
        when paso % cada == 0 || paso == pasos {
            hold ms = msPorPaso(rdtsc() - t0, paso - ultimo)
            logLinea(paso, perdida, optUltimoLr(opt), norma, ms, paresPorSegundo(n, ms))
            ultimo = paso
            t0 = rdtsc()
        }
    }
}

// XOR: 4 muestras en {-1, 1}², clase 1 si los signos difieren.
flow aprenderXor() => Bool {
    logTexto(cadena("-- XOR (MLP 2-16-2, AdamW lr 0,05, 600 pasos)\n"))
    hold g = montonReservar(16)
    pcgSembrar(g, 7, 11)
    hold m = mlpNuevo(4, 2, 16, 2, 0, g)
    hold x = leer64(m + 32)
    hold tgt = montonReservar(32)
    each i among 0..4 {
        hold a = i & 1
        hold b = (i >> 1) & 1
        tEscribir(x, i, 0, Float(2 * a - 1))
        tEscribir(x, i, 1, Float(2 * b - 1))
        escribir64(tgt + i * 8, a ^ b)
    }
    hold opt = optNuevo(4, 0.05, 0.9, 0.999, 0.00000001, 0.01, 20, 600, 0.0005, 5.0)
    mlpRegistrar(opt, m)
    mlpEntrenar(m, opt, tgt, 600, 100)
    mlpAdelante(m)
    hold perdida = opEntropiaCruzada(leer64(m + 72), tgt, false, 1.0)
    hold aciertos = mlpAciertos(m, tgt)
    logTexto(cadena("XOR: pérdida "))
    logDecimal(perdida, 5)
    logTexto(cadena(", aciertos "))
    logEntero(aciertos)
    logTexto(cadena("/4\n"))
    give perdida < 0.01 && aciertos == 4
}

// Rellena n puntos de dos círculos (radios 0,6 y 1,0, ruido ±0,12).
flow circulos(g: Int, x: Int, tgt: Int, n: Int) {
    each i among 0..n {
        hold clase = i & 1
        change r = 0.6
        when clase == 1 { r = 1.0 }
        r = r + pcgEntre(g, -0.12, 0.12)
        hold ang = pcgEntre(g, 0.0, 2.0 * PI)
        tEscribir(x, i, 0, r * cosF(ang))
        tEscribir(x, i, 1, r * cosF(ang - PI / 2.0))
        escribir64(tgt + i * 8, clase)
    }
}

flow aprenderCirculos() => Bool {
    logTexto(cadena("-- Dos círculos (MLP 2-32-2, AdamW lr 0,03, 800 pasos, 256+256 puntos)\n"))
    hold g = montonReservar(16)
    pcgSembrar(g, 2024, 5)
    hold m = mlpNuevo(256, 2, 32, 2, 0, g)
    hold prueba = mlpNuevo(256, 2, 32, 2, m, g)
    hold tgt = montonReservar(2048)
    hold tgt_prueba = montonReservar(2048)
    circulos(g, leer64(m + 32), tgt, 256)
    circulos(g, leer64(prueba + 32), tgt_prueba, 256)
    hold opt = optNuevo(4, 0.03, 0.9, 0.999, 0.00000001, 0.01, 40, 800, 0.0003, 5.0)
    mlpRegistrar(opt, m)
    mlpEntrenar(m, opt, tgt, 800, 200)
    mlpAdelante(m)
    hold ac_ent = mlpAciertos(m, tgt)
    mlpAdelante(prueba)
    hold ac_prueba = mlpAciertos(prueba, tgt_prueba)
    logTexto(cadena("círculos: entrenamiento "))
    logEntero(ac_ent)
    logTexto(cadena("/256, prueba "))
    logEntero(ac_prueba)
    logTexto(cadena("/256\n"))
    give ac_prueba * 100 >= 95 * 256
}

// ---- bigramas por bytes -----------------------------------------------------------
// Texto cargado: +0 dirección, +8 longitud.
flow textoReg() => Int { give reservar(16, 8) }

// 1 = cargado, 0 = omitido (no existe o < 4 KiB), -1 = error de lectura.
flow textoCargar() => Int {
    escribir64(textoReg(), 0)
    escribir64(textoReg() + 8, 0)
    when !discoHayPermitida() || !fatMontar() {
        kprintln(cadena("bigramas: sin partición FAT32, prueba omitida"))
        give 0
    }
    when !fatAbrir(cadena("texto.txt")) {
        kprintln(cadena("bigramas: no hay texto.txt, prueba omitida"))
        give 0
    }
    hold tam = fatTamanoArchivo()
    when tam < 4096 {
        kprintln(cadena("bigramas: texto.txt es diminuto (< 4 KiB), prueba omitida"))
        give 0
    }
    hold buf = montonReservar(tam + 65536)
    when buf == 0 { give 0 - 1 }
    when fatLeer(0, tam, buf) != tam { give 0 - 1 }
    escribir64(textoReg(), buf)
    escribir64(textoReg() + 8, tam)
    give 1
}

// Cuenta los pares (a, b) consecutivos de texto[desde, hasta) en cuentas[a*256+b].
flow contarPares(texto: Int, desde: Int, hasta: Int, cuentas: Int) {
    each k among 0..65536 { escribir64(cuentas + k * 8, 0) }
    each i among desde..hasta - 1 {
        hold k = leer8(texto + i) * 256 + leer8(texto + i + 1)
        escribir64(cuentas + k * 8, leer64(cuentas + k * 8) + 1)
    }
}

// Entropía de bigramas H = -Σ p(a,b) ln p(b|a), en nats, a partir de conteos.
flow entropiaBigramas(cuentas: Int, total: Int) => Float {
    change suma = 0.0
    each a among 0..256 {
        change fila = 0
        each b among 0..256 { fila += leer64(cuentas + (a * 256 + b) * 8) }
        each b among 0..256 {
            hold c = leer64(cuentas + (a * 256 + b) * 8)
            when c > 0 { suma = suma + Float(c) * logF(Float(c) / Float(fila)) }
        }
    }
    give 0.0 - suma / Float(total)
}

// Pérdida exacta de la tabla w sobre todos los pares contados (sin muestreo):
// -Σ c(a,b) ln softmax(w[a])[b] / total.
flow perdidaExacta(w: Int, cuentas: Int, total: Int) => Float {
    change suma = 0.0
    each a among 0..256 {
        change fila = 0
        each b among 0..256 { fila += leer64(cuentas + (a * 256 + b) * 8) }
        when fila > 0 {
            change maximo = tLeer(w, a, 0)
            each b among 1..256 {
                when tLeer(w, a, b) > maximo { maximo = tLeer(w, a, b) }
            }
            change z = 0.0
            each b among 0..256 { z = z + expF(tLeer(w, a, b) - maximo) }
            hold lse = maximo + logF(z)
            each b among 0..256 {
                hold c = leer64(cuentas + (a * 256 + b) * 8)
                when c > 0 { suma = suma + Float(c) * (lse - tLeer(w, a, b)) }
            }
        }
    }
    give suma / Float(total)
}

// 1 = pasa, 0 = omitida, -1 = falla.
flow aprenderBigramas(carga: Int) => Int {
    when carga <= 0 { give carga }
    hold texto = leer64(textoReg())
    hold largo = leer64(textoReg() + 8)
    hold corte = largo / 10 * 9
    hold total_ent = corte - 1
    hold total_val = largo - corte - 1
    hold cuentas = montonReservar(65536 * 8)
    hold cuentas_val = montonReservar(65536 * 8)
    when cuentas == 0 || cuentas_val == 0 { give 0 - 1 }

    contarPares(texto, 0, corte, cuentas)
    contarPares(texto, corte, largo, cuentas_val)
    hold h = entropiaBigramas(cuentas, total_ent)
    hold h_val = entropiaBigramas(cuentas_val, total_val)
    change observados = 0
    each k among 0..65536 {
        when leer64(cuentas + k * 8) > 0 { observados += 1 }
    }

    logTexto(cadena("-- Bigramas por bytes: texto "))
    logEntero(largo)
    logTexto(cadena(" bytes, entrenamiento "))
    logEntero(corte)
    logTexto(cadena(", validación "))
    logEntero(largo - corte)
    logTexto(cadena("\n   pares distintos "))
    logEntero(observados)
    logTexto(cadena(", H(entrenamiento) = "))
    logDecimal(h, 4)
    logTexto(cadena(" nats, H(validación) = "))
    logDecimal(h_val, 4)
    logTexto(cadena(" nats, ln 256 = 5,5452\n"))

    hold w = tNuevo(256, 256, F32, true)
    hold logits = tNuevo(BG_LOTE, 256, F32, true)
    hold ids = montonReservar(BG_LOTE * 8)
    hold tgt = montonReservar(BG_LOTE * 8)
    hold g = montonReservar(16)
    pcgSembrar(g, 99, 3)
    hold opt = optNuevo(1, 0.1, 0.9, 0.999, 0.00000001, 0.0, BG_WARMUP, BG_PASOS, 0.001, 1.0)
    optAnadir(opt, w, false)

    logTexto(cadena("paso 0 pérdida exacta de entrenamiento "))
    logDecimal(perdidaExacta(w, cuentas, total_ent), 4)
    logByte(10)

    change t0 = rdtsc()
    change ultimo = 0
    hold fin = BG_PASOS + 1
    each paso among 1..fin {
        each i among 0..BG_LOTE {
            hold p = pcgEntero(g, total_ent)
            escribir64(ids + i * 8, leer8(texto + p))
            escribir64(tgt + i * 8, leer8(texto + p + 1))
        }
        optCeros(opt)
        tCerosGrad(logits)
        opEmbedding(w, ids, logits)
        hold perdida = opEntropiaCruzada(logits, tgt, true, 1.0)
        opEmbeddingAtras(w, ids, logits)
        hold norma = optPaso(opt)
        when paso % BG_CADA == 0 || paso == BG_PASOS {
            hold ms = msPorPaso(rdtsc() - t0, paso - ultimo)
            logLinea(paso, perdida, optUltimoLr(opt), norma, ms, paresPorSegundo(BG_LOTE, ms))
            ultimo = paso
            logTexto(cadena("      pérdida exacta de entrenamiento "))
            logDecimal(perdidaExacta(w, cuentas, total_ent), 4)
            logByte(10)
            t0 = rdtsc()
        }
    }

    hold p_ent = perdidaExacta(w, cuentas, total_ent)
    hold p_val = perdidaExacta(w, cuentas_val, total_val)
    logTexto(cadena("bigramas: H = "))
    logDecimal(h, 4)
    logTexto(cadena(" nats, pérdida de entrenamiento "))
    logDecimal(p_ent, 4)
    logTexto(cadena(" (exceso "))
    logDecimal(p_ent - h, 4)
    logTexto(cadena("), pérdida de validación "))
    logDecimal(p_val, 4)
    logTexto(cadena(" (H validación "))
    logDecimal(h_val, 4)
    logTexto(cadena(")\n"))
    when absF(p_ent - h) <= 0.05 { give 1 }
    give 0 - 1
}

// Hito 16 completo: true si XOR + círculos pasan y los bigramas pasan o se omiten.
expose flow aprenderTodo() => Bool {
    // texto.txt se lee antes de abrir el log (fatAbrir cambia de archivo).
    hold carga = textoCargar()
    logAbrir()
    hold xor = aprenderXor()
    hold circ = aprenderCirculos()
    hold bigr = aprenderBigramas(carga)
    hold log_ok = logCerrar()
    when !log_ok { kprintln(cadena("aviso: no se pudo cerrar ENTRENA.LOG")) }
    when !xor { kprintln(cadena("XOR: FALLÓ")) }
    when !circ { kprintln(cadena("círculos: FALLÓ")) }
    when bigr < 0 { kprintln(cadena("bigramas: FALLÓ")) }
    when bigr == 0 { kprintln(cadena("bigramas: omitido")) }
    give xor && circ && bigr >= 0
}
