// ============================================================================
// PROYECTO ENCA — FASE 1 & 2: NÚCLEO MATEMÁTICO Y EXPERIMENTO ENCA-EXP-001
// Archivo: examples/enca_exp001_v2.l
// Sintaxis: ELE v2 Canónica
// Etapa objetivo: Stage 0 (backends: rustc | cranelift)
// Estado: IMPLEMENTADO (listo para validación local con CLI `l`)
// ============================================================================

// --- 1. NÚCLEO MATEMÁTICO PURO EN ELE V2 ---

flow absFloat(x: Float) => Float {
    when x < 0.0 {
        give 0.0 - x
    }
    give x
}

flow maxFloat(a: Float, b: Float) => Float {
    when a > b {
        give a
    }
    give b
}

flow clampFloat(x: Float, minVal: Float, maxVal: Float) => Float {
    when x < minVal {
        give minVal
    }
    when x > maxVal {
        give maxVal
    }
    give x
}

// Aproximación racional de Padé [5/4] para tanh(x)
flow tanhFloat(x: Float) => Float {
    when x > 4.97 {
        give 1.0
    }
    when x < -4.97 {
        give -1.0
    }
    hold x2 = x * x
    hold x4 = x2 * x2
    hold x6 = x4 * x2
    hold num = x * (135135.0 + 17325.0 * x2 + 378.0 * x4)
    hold den = 135135.0 + 62370.0 * x2 + 3150.0 * x4 + 28.0 * x6
    give num / den
}

// Raíz cuadrada mediante iteración de Newton-Raphson
flow sqrtFloat(x: Float) => Float {
    when x <= 0.0 {
        give 0.0
    }
    change g = x
    when g > 1.0 {
        g = x * 0.5
    } otherwise {
        g = 1.0
    }
    each iter among 0..10 {
        g = 0.5 * (g + x / g)
    }
    give g
}

// Exponencial estable mediante reducción de rango (x / 16) y serie de Taylor
flow expFloat(x: Float) => Float {
    hold xc = clampFloat(x, -16.0, 16.0)
    hold u = xc * 0.0625
    hold u2 = u * u
    hold u3 = u2 * u
    hold u4 = u3 * u
    hold u5 = u4 * u
    change p = 1.0 + u + (u2 * 0.5) + (u3 / 6.0) + (u4 / 24.0) + (u5 / 120.0)
    p = p * p
    p = p * p
    p = p * p
    p = p * p
    give p
}

// Logaritmo natural estable para sorpresa S(t) = -ln P(y)
flow lnFloat(x: Float) => Float {
    hold xc = maxFloat(x, 0.0000001)
    change y = xc
    change k = 0.0
    during y > 2.0 {
        y = y * 0.5
        k += 1.0
    }
    during y < 0.5 {
        y = y * 2.0
        k -= 1.0
    }
    hold z = (y - 1.0) / (y + 1.0)
    hold z2 = z * z
    hold z4 = z2 * z2
    hold serie = z * (1.0 + (z2 / 3.0) + (z4 / 5.0) + (z4 * z2 / 7.0))
    give 2.0 * serie + k * 0.69314718056
}

flow digitoAFloat(d: Int) => Float {
    when d == 1 { give 1.0 }
    when d == 2 { give 2.0 }
    when d == 3 { give 3.0 }
    when d == 4 { give 4.0 }
    when d == 5 { give 5.0 }
    when d == 6 { give 6.0 }
    when d == 7 { give 7.0 }
    when d == 8 { give 8.0 }
    when d == 9 { give 9.0 }
    give 0.0
}

flow intAFloatRango(n: Int) => Float {
    change v = n
    when v < 0 {
        v = 0 - v
    }
    hold d4 = (v / 10000) % 10
    hold d3 = (v / 1000) % 10
    hold d2 = (v / 100) % 10
    hold d1 = (v / 10) % 10
    hold d0 = v % 10
    give digitoAFloat(d4) * 10000.0 + digitoAFloat(d3) * 1000.0 + digitoAFloat(d2) * 100.0 + digitoAFloat(d1) * 10.0 + digitoAFloat(d0)
}

// --- 2. GENERADOR PSEUDOALEATORIO Y PESOS PROCEDURALES (LEHMER MINSTD) ---

expose shape Rng {
    estado: Int = 1337
}

extend Rng {
    direct flow nuevo(semilla: Int) => Rng {
        change s = semilla
        when s <= 0 {
            s = 1337
        }
        give Rng(estado: s)
    }

    exclusive flow siguienteInt() => Int {
        hold m = 2147483647
        hold a = 48271
        this.estado = (this.estado * a) % m
        give this.estado
    }

    exclusive flow uniformeSimetrico(escala: Float) => Float {
        hold r = this@siguienteInt() % 10000
        hold frac = intAFloatRango(r) * 0.0001
        give (frac * 2.0 - 1.0) * escala
    }
}

// --- 3. NÚCLEO EXPERIMENTAL ENCA-CORE ---

expose shape EncaCore {
    nIn: Int = 4
    nHid: Int = 16
    kActivas: Int = 4
    nOut: Int = 2
    entrenarInternos: Bool = true
    usarFiltroPredictivo: Bool = true

    wIn: List of[Float]
    wRec: List of[Float]
    wPredIn: List of[Float]
    wOut: List of[Float]
    bHid: List of[Float]
    bOut: List of[Float]
    bRetro: List of[Float]

    alphas: List of[Float]
    vMem: List of[Float]
    sAct: List of[Float]
    sPrev: List of[Float]
    umbrales: List of[Float]
    mascaraActiva: List of[Int]
    indicesActivosPrev: List of[Int]
    numActivasPrev: Int = 0

    filtroIn: List of[Float]
    filtroRec: List of[Float]
    trazaIn: List of[Float]
    trazaRec: List of[Float]

    eventosDisparados: Int = 0
    pasosEjecutados: Int = 0
    macsEjecutadas: Int = 0
    macsDensasRef: Int = 0
    maxPotencialObs: Float = 0.0
}

extend EncaCore {
    direct flow crear(semilla: Int, kActivasConfig: Int, entrenarPesosInternos: Bool, filtroPred: Bool) => EncaCore {
        change rng = Rng@nuevo(semilla)
        hold nIn = 4
        hold nHid = 16
        hold nOut = 2

        change wIn: List of[Float] = List[]
        change wPredIn: List of[Float] = List[]
        change filtroIn: List of[Float] = List[]
        change trazaIn: List of[Float] = List[]
        each i among 0..(nHid * nIn) {
            wIn@push(rng@uniformeSimetrico(0.65))
            wPredIn@push(rng@uniformeSimetrico(0.15))
            filtroIn@push(0.0)
            trazaIn@push(0.0)
        }

        change wRec: List of[Float] = List[]
        change filtroRec: List of[Float] = List[]
        change trazaRec: List of[Float] = List[]
        each i among 0..(nHid * nHid) {
            wRec@push(rng@uniformeSimetrico(0.35))
            filtroRec@push(0.0)
            trazaRec@push(0.0)
        }

        change wOut: List of[Float] = List[]
        change bRetro: List of[Float] = List[]
        each i among 0..(nOut * nHid) {
            hold p = rng@uniformeSimetrico(0.45)
            wOut@push(p)
            bRetro@push(p)
        }

        change alphas: List of[Float] = List[]
        change bHid: List of[Float] = List[]
        change vMem: List of[Float] = List[]
        change sAct: List of[Float] = List[]
        change sPrev: List of[Float] = List[]
        change umbrales: List of[Float] = List[]
        change mascaraActiva: List of[Int] = List[]
        change indicesActivosPrev: List of[Int] = List[]

        each i among 0..nHid {
            when i < 8 {
                alphas@push(0.55)
            } otherwise {
                alphas@push(0.88)
            }
            bHid@push(0.0)
            vMem@push(0.0)
            sAct@push(0.0)
            sPrev@push(0.0)
            when kActivasConfig < nHid {
                umbrales@push(0.06)
            } otherwise {
                umbrales@push(0.0)
            }
            mascaraActiva@push(0)
            indicesActivosPrev@push(0)
        }

        change bOut: List of[Float] = List[]
        each o among 0..nOut {
            bOut@push(0.0)
        }

        give EncaCore(
            nIn: nIn,
            nHid: nHid,
            kActivas: kActivasConfig,
            nOut: nOut,
            entrenarInternos: entrenarPesosInternos,
            usarFiltroPredictivo: filtroPred,
            wIn: wIn,
            wRec: wRec,
            wPredIn: wPredIn,
            wOut: wOut,
            bHid: bHid,
            bOut: bOut,
            bRetro: bRetro,
            alphas: alphas,
            vMem: vMem,
            sAct: sAct,
            sPrev: sPrev,
            umbrales: umbrales,
            mascaraActiva: mascaraActiva,
            indicesActivosPrev: indicesActivosPrev,
            numActivasPrev: 0,
            filtroIn: filtroIn,
            filtroRec: filtroRec,
            trazaIn: trazaIn,
            trazaRec: trazaRec,
            eventosDisparados: 0,
            pasosEjecutados: 0,
            macsEjecutadas: 0,
            macsDensasRef: 0,
            maxPotencialObs: 0.0
        )
    }

    exclusive flow reiniciarEstadoEpisodio() {
        each i among 0..this.nHid {
            this.vMem[i] = 0.0
            this.sAct[i] = 0.0
            this.sPrev[i] = 0.0
            this.mascaraActiva[i] = 0
            this.indicesActivosPrev[i] = 0
        }
        this.numActivasPrev = 0

        each i among 0..(this.nHid * this.nIn) {
            this.filtroIn[i] = 0.0
            this.trazaIn[i] = 0.0
        }
        each i among 0..(this.nHid * this.nHid) {
            this.filtroRec[i] = 0.0
            this.trazaRec[i] = 0.0
        }
    }

    exclusive flow pasoTemporal(entrada: view [Float], acumularTrazas: Bool) {
        hold gammaTraza = 0.86
        hold umbralSensorial = 0.04

        this.pasosEjecutados += 1
        this.macsDensasRef += (this.nHid * this.nIn) + (this.nHid * this.nHid)

        change conteoPrev = 0
        each i among 0..this.nHid {
            this.sPrev[i] = this.sAct[i]
            when this.mascaraActiva[i] == 1 {
                this.indicesActivosPrev[conteoPrev] = i
                conteoPrev += 1
            }
            this.sAct[i] = 0.0
        }
        this.numActivasPrev = conteoPrev

        change errIn: [Float; 4] = [0.0, 0.0, 0.0, 0.0]
        each j among 0..this.nIn {
            when this.usarFiltroPredictivo {
                change predJ = 0.0
                each idxAct among 0..this.numActivasPrev {
                    hold r = this.indicesActivosPrev[idxAct]
                    predJ += this.wPredIn[r * this.nIn + j] * this.sPrev[r]
                    this.macsEjecutadas += 1
                }
                errIn[j] = entrada[j] - predJ
            } otherwise {
                errIn[j] = entrada[j]
            }
        }

        each i among 0..this.nHid {
            hold alphaI = this.alphas[i]
            change u = this.bHid[i]

            each j among 0..this.nIn {
                when absFloat(errIn[j]) > umbralSensorial {
                    u += this.wIn[i * this.nIn + j] * errIn[j]
                    this.macsEjecutadas += 1
                }
            }

            each idxAct among 0..this.numActivasPrev {
                hold r = this.indicesActivosPrev[idxAct]
                u += this.wRec[i * this.nHid + r] * this.sPrev[r]
                this.macsEjecutadas += 1
            }

            hold nuevoV = alphaI * this.vMem[i] + (1.0 - alphaI) * u
            this.vMem[i] = nuevoV
            hold absV = absFloat(nuevoV)
            when absV > this.maxPotencialObs {
                this.maxPotencialObs = absV
            }
            this.mascaraActiva[i] = 0
        }

        each turno among 0..this.kActivas {
            change mejorIdx = -1
            change mejorMargen = 0.0

            each i among 0..this.nHid {
                when this.mascaraActiva[i] == 0 {
                    hold margen = absFloat(this.vMem[i]) - this.umbrales[i]
                    when margen > mejorMargen {
                        mejorMargen = margen
                        mejorIdx = i
                    }
                }
            }

            when mejorIdx >= 0 {
                this.mascaraActiva[mejorIdx] = 1
                this.sAct[mejorIdx] = tanhFloat(this.vMem[mejorIdx])
                this.eventosDisparados += 1
            }
        }

        each i among 0..this.nHid {
            hold alphaI = this.alphas[i]
            hold activa = this.mascaraActiva[i]

            when this.kActivas < this.nHid {
                when activa == 1 {
                    this.umbrales[i] = clampFloat(this.umbrales[i] + 0.0015 * 0.75, 0.01, 0.50)
                } otherwise {
                    this.umbrales[i] = clampFloat(this.umbrales[i] - 0.0015 * 0.25, 0.01, 0.50)
                }
            }

            when acumularTrazas {
                hold vI = this.vMem[i]
                hold thv = tanhFloat(vI)
                change psi = 1.0 - (thv * thv)
                when psi < 0.05 {
                    psi = 0.05
                }
                when absFloat(vI) < (0.5 * this.umbrales[i]) {
                    psi = 0.0
                }

                each j among 0..this.nIn {
                    hold idxIn = i * this.nIn + j
                    hold fIn = alphaI * this.filtroIn[idxIn] + (1.0 - alphaI) * errIn[j]
                    this.filtroIn[idxIn] = fIn
                    this.trazaIn[idxIn] = gammaTraza * this.trazaIn[idxIn] + psi * fIn

                    when this.usarFiltroPredictivo && (activa == 1) {
                        this.wPredIn[idxIn] += 0.01 * errIn[j] * this.sPrev[i]
                    }
                }

                each r among 0..this.nHid {
                    hold idxRec = i * this.nHid + r
                    hold fRec = alphaI * this.filtroRec[idxRec] + (1.0 - alphaI) * this.sPrev[r]
                    this.filtroRec[idxRec] = fRec
                    this.trazaRec[idxRec] = gammaTraza * this.trazaRec[idxRec] + psi * fRec
                }
            }
        }
    }

    exclusive flow evaluarYAprender(objetivo: Int, lr: Float, aprender: Bool, sorpresaOut: edit Float) => Int {
        change logits: [Float; 2] = [this.bOut[0], this.bOut[1]]

        each o among 0..this.nOut {
            each i among 0..this.nHid {
                when this.mascaraActiva[i] == 1 {
                    logits[o] += this.wOut[o * this.nHid + i] * this.sAct[i]
                    this.macsEjecutadas += 1
                }
            }
        }
        this.macsDensasRef += (this.nOut * this.nHid)

        hold m = maxFloat(logits[0], logits[1])
        hold e0 = expFloat(logits[0] - m)
        hold e1 = expFloat(logits[1] - m)
        hold sumaExp = e0 + e1
        hold lnSuma = lnFloat(sumaExp)
        hold probs: [Float; 2] = [e0 / sumaExp, e1 / sumaExp]

        change logitTarget = logits[0]
        when objetivo == 1 {
            logitTarget = logits[1]
        }
        hold sorpresa = clampFloat((0.0 - (logitTarget - m)) + lnSuma, 0.0, 5.0)
        sorpresaOut = sorpresa

        when aprender {
            change deltaOut: [Float; 2] = [probs[0], probs[1]]
            when objetivo == 0 {
                deltaOut[0] -= 1.0
            } otherwise {
                deltaOut[1] -= 1.0
            }

            hold modulador = clampFloat(0.5 + 0.4 * sorpresa, 0.5, 2.5)
            hold decay = 0.0003

            when this.entrenarInternos {
                each i among 0..this.nHid {
                    hold errProyectado = this.bRetro[0 * this.nHid + i] * deltaOut[0] + this.bRetro[1 * this.nHid + i] * deltaOut[1]
                    hold senalLocal = modulador * errProyectado

                    each j among 0..this.nIn {
                        hold idxIn = i * this.nIn + j
                        hold gradIn = clampFloat(senalLocal * this.trazaIn[idxIn], -1.0, 1.0)
                        this.wIn[idxIn] -= lr * (gradIn + decay * this.wIn[idxIn])
                    }

                    each r among 0..this.nHid {
                        hold idxRec = i * this.nHid + r
                        hold gradRec = clampFloat(senalLocal * this.trazaRec[idxRec], -1.0, 1.0)
                        this.wRec[idxRec] -= lr * (gradRec + decay * this.wRec[idxRec])
                    }
                }
            }

            each o among 0..this.nOut {
                this.bOut[o] -= lr * deltaOut[o]
                each i among 0..this.nHid {
                    hold idxOut = o * this.nHid + i
                    this.wOut[idxOut] -= lr * (deltaOut[o] * this.sAct[i] + decay * this.wOut[idxOut])
                    this.bRetro[idxOut] = this.wOut[idxOut]
                }
            }
        }

        when probs[1] > probs[0] {
            give 1
        }
        give 0
    }

    flow normaFrobeniusPesos() => Float {
        change sumaCuad = 0.0
        each i among 0..(this.nHid * this.nIn) {
            hold w = this.wIn[i]
            sumaCuad += w * w
        }
        each i among 0..(this.nHid * this.nHid) {
            hold w = this.wRec[i]
            sumaCuad += w * w
        }
        give sqrtFloat(sumaCuad)
    }
}

// --- 4. EJECUCIÓN DEL PROTOCOLO EXPERIMENTAL ENCA-EXP-001 ---

flow ejecutarEpisodioXor(
    modelo: edit EncaCore,
    rngRuido: edit Rng,
    b1: Int,
    b2: Int,
    retardoD: Int,
    lr: Float,
    entrenar: Bool,
    sorpresaEpisodio: edit Float
) => Int {
    modelo@reiniciarEstadoEpisodio()

    change vInicial: [Float; 4] = [
        rngRuido@uniformeSimetrico(0.03),
        rngRuido@uniformeSimetrico(0.03),
        rngRuido@uniformeSimetrico(0.03),
        0.0
    ]
    when b1 == 0 {
        vInicial[0] += 1.0
    } otherwise {
        vInicial[1] += 1.0
    }
    modelo@pasoTemporal(view vInicial, entrenar)

    each pasoRuido among 0..retardoD {
        hold vRuido: [Float; 4] = [
            rngRuido@uniformeSimetrico(0.03),
            rngRuido@uniformeSimetrico(0.03),
            1.0 + rngRuido@uniformeSimetrico(0.03),
            0.0
        ]
        modelo@pasoTemporal(view vRuido, entrenar)
    }

    change vConsulta: [Float; 4] = [
        rngRuido@uniformeSimetrico(0.03),
        rngRuido@uniformeSimetrico(0.03),
        0.0,
        1.0
    ]
    when b2 == 0 {
        vConsulta[0] += 1.0
    } otherwise {
        vConsulta[1] += 1.0
    }
    modelo@pasoTemporal(view vConsulta, entrenar)

    change etiquetaXor = 0
    when b1 != b2 {
        etiquetaXor = 1
    }

    hold pred = modelo@evaluarYAprender(etiquetaXor, lr, entrenar, edit sorpresaEpisodio)
    when pred == etiquetaXor {
        give 1
    }
    give 0
}

flow evaluarModeloEnRetardo(
    nombreModelo: Text,
    semilla: Int,
    retardoD: Int,
    kActivas: Int,
    entrenarInternos: Bool,
    usarPred: Bool
) {
    change modelo = EncaCore@crear(semilla, kActivas, entrenarInternos, usarPred)
    change rngTrain = Rng@nuevo(semilla + 500)
    change rngTest = Rng@nuevo(semilla + 9000)

    hold epocas = 90
    hold lr = 0.065
    change sorpresaTemp = 0.0

    each epoca among 1..=epocas {
        hold c00 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 0, 0, retardoD, lr, true, edit sorpresaTemp)
        hold c01 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 0, 1, retardoD, lr, true, edit sorpresaTemp)
        hold c10 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 1, 0, retardoD, lr, true, edit sorpresaTemp)
        hold c11 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 1, 1, retardoD, lr, true, edit sorpresaTemp)
    }

    modelo.eventosDisparados = 0
    modelo.pasosEjecutados = 0
    modelo.macsEjecutadas = 0
    modelo.macsDensasRef = 0

    change aciertosTest = 0
    change sumaSorpresaTest = 0.0
    each rep among 0..10 {
        aciertosTest += ejecutarEpisodioXor(edit modelo, edit rngTest, 0, 0, retardoD, 0.0, false, edit sorpresaTemp)
        sumaSorpresaTest += sorpresaTemp
        aciertosTest += ejecutarEpisodioXor(edit modelo, edit rngTest, 0, 1, retardoD, 0.0, false, edit sorpresaTemp)
        sumaSorpresaTest += sorpresaTemp
        aciertosTest += ejecutarEpisodioXor(edit modelo, edit rngTest, 1, 0, retardoD, 0.0, false, edit sorpresaTemp)
        sumaSorpresaTest += sorpresaTemp
        aciertosTest += ejecutarEpisodioXor(edit modelo, edit rngTest, 1, 1, retardoD, 0.0, false, edit sorpresaTemp)
        sumaSorpresaTest += sorpresaTemp
    }

    hold totalOportunidadesDisparo = modelo.pasosEjecutados * modelo.nHid
    hold unidadesSilentes = totalOportunidadesDisparo - modelo.eventosDisparados
    hold normaW = modelo@normaFrobeniusPesos()

    print("[{nombreModelo} | Semilla={semilla} | Retardo D={retardoD}]")
    print("  -> Aciertos Test (sobre 40): {aciertosTest} | Sorpresa acumulada: {sumaSorpresaTest}")
    print("  -> Unidades silentes: {unidadesSilentes} / {totalOportunidadesDisparo} | MACs ejecutadas: {modelo.macsEjecutadas} (Ref Densa: {modelo.macsDensasRef})")
    print("  -> Estabilidad: Max |v_i|={modelo.maxPotencialObs} | ||W||_F={normaW}")
}

flow main() => Int {
    print("======================================================================")
    print("ELE NEUROLAB — EXPERIMENTO ENCA-EXP-001 (SINTAXIS CANÓNICA ELE V2)")
    print("======================================================================")

    print("--- COMPARATIVA CONTRA BASELINES (RETARDO D=4, SEMILLA=101) ---")
    evaluarModeloEnRetardo("BASELINE-RESERVOIR (Pesos fijos, k=16)", 101, 4, 16, false, false)
    evaluarModeloEnRetardo("BASELINE-RNN-DENSA (Regla local, k=16)", 101, 4, 16, true, false)
    evaluarModeloEnRetardo("ENCA-CORE (Eventos + Top-k=4, 75% disperso)", 101, 4, 4, true, true)

    print("--- EVALUACION MULTI-SEMILLA Y MULTI-RETARDO DE ENCA-CORE (k=4) ---")
    hold semillas: [Int; 3] = [101, 202, 303]
    hold retardos: [Int; 3] = [2, 4, 8]

    each s among semillas {
        each d among retardos {
            evaluarModeloEnRetardo("ENCA-CORE", s, d, 4, true, true)
        }
    }

    give 0
}