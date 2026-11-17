// ============================================================================
// PROYECTO ENCA — FASE 3: MEMORIA EPISÓDICA HIPOCAMPAL Y COMPUERTA DE NOVEDAD
// Archivo: examples/enca_exp002_hipocampo.l
// Sintaxis: ELE v2 Canónica
// Etapa objetivo: Stage 0 (backends: cranelift | rustc)
// Objetivo: Resolver pérdida de memoria en retardos largos (D=2, 4, 8, 16)
//           y reducir reallocs de heap a 0 mediante pre-reserva explícita.
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

// --- 2. GENERADOR PSEUDOALEATORIO REPRODUCIBLE (LEHMER MINSTD) ---

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

// --- 3. ARQUITECTURA ENCA-CORE + MEMORIA EPISÓDICA HIPOCAMPAL (FASE 3) ---

expose shape EncaSistemaCognitivo {
    nIn: Int = 4
    nHid: Int = 16
    kActivas: Int = 4
    nOut: Int = 2
    entrenarInternos: Bool = true
    usarHipocampo: Bool = true

    // Pesos sinápticos corticales (con capacidad reservada para 0 reallocs)
    wIn: List of[Float]
    wRec: List of[Float]
    wBind: List of[Float]
    wOut: List of[Float]
    bHid: List of[Float]
    bOut: List of[Float]
    bRetro: List of[Float]

    // Estado dinámico cortical y habituación talámica
    alphas: List of[Float]
    mediaHabituacion: List of[Float]
    vMem: List of[Float]
    sAct: List of[Float]
    sPrev: List of[Float]
    umbrales: List of[Float]
    mascaraActiva: List of[Int]
    indicesActivosPrev: List of[Int]
    numActivasPrev: Int = 0

    // Memoria Episódica Rápida (Hipocampo CA3-CA1: escritura One-Shot por sorpresa)
    hipSlotSensorial: List of[Float]
    hipSlotCortical: List of[Float]
    hipOcupado: Int = 0

    // Filtros pre-sinápticos y trazas de elegibilidad locales
    filtroIn: List of[Float]
    filtroRec: List of[Float]
    trazaIn: List of[Float]
    trazaRec: List of[Float]

    // Telemetría experimental
    eventosDisparados: Int = 0
    escriturasHipocampo: Int = 0
    pasosEjecutados: Int = 0
    macsEjecutadas: Int = 0
    macsDensasRef: Int = 0
    maxPotencialObs: Float = 0.0
}

extend EncaSistemaCognitivo {
    direct flow crear(semilla: Int, kConfig: Int, entrenarInt: Bool, activarHipocampo: Bool) => EncaSistemaCognitivo {
        change rng = Rng@nuevo(semilla)
        hold nIn = 4
        hold nHid = 16
        hold nOut = 2
        hold tamIn = nHid * nIn
        hold tamRec = nHid * nHid
        hold tamOut = nOut * nHid

        change wIn: List of[Float] = List[]
        wIn@reserve(tamIn)
        change wBind: List of[Float] = List[]
        wBind@reserve(tamIn)
        change filtroIn: List of[Float] = List[]
        filtroIn@reserve(tamIn)
        change trazaIn: List of[Float] = List[]
        trazaIn@reserve(tamIn)

        each i among 0..tamIn {
            wIn@push(rng@uniformeSimetrico(0.70))
            wBind@push(rng@uniformeSimetrico(0.70))
            filtroIn@push(0.0)
            trazaIn@push(0.0)
        }

        change wRec: List of[Float] = List[]
        wRec@reserve(tamRec)
        change filtroRec: List of[Float] = List[]
        filtroRec@reserve(tamRec)
        change trazaRec: List of[Float] = List[]
        trazaRec@reserve(tamRec)

        each i among 0..tamRec {
            wRec@push(rng@uniformeSimetrico(0.30))
            filtroRec@push(0.0)
            trazaRec@push(0.0)
        }

        change wOut: List of[Float] = List[]
        wOut@reserve(tamOut)
        change bRetro: List of[Float] = List[]
        bRetro@reserve(tamOut)

        each i among 0..tamOut {
            hold p = rng@uniformeSimetrico(0.50)
            wOut@push(p)
            bRetro@push(p)
        }

        change alphas: List of[Float] = List[]
        alphas@reserve(nHid)
        change bHid: List of[Float] = List[]
        bHid@reserve(nHid)
        change vMem: List of[Float] = List[]
        vMem@reserve(nHid)
        change sAct: List of[Float] = List[]
        sAct@reserve(nHid)
        change sPrev: List of[Float] = List[]
        sPrev@reserve(nHid)
        change umbrales: List of[Float] = List[]
        umbrales@reserve(nHid)
        change mascaraActiva: List of[Int] = List[]
        mascaraActiva@reserve(nHid)
        change indicesActivosPrev: List of[Int] = List[]
        indicesActivosPrev@reserve(nHid)
        change hipSlotCortical: List of[Float] = List[]
        hipSlotCortical@reserve(nHid)

        each i among 0..nHid {
            when i < 8 {
                alphas@push(0.60)
            } otherwise {
                alphas@push(0.92)
            }
            bHid@push(0.0)
            vMem@push(0.0)
            sAct@push(0.0)
            sPrev@push(0.0)
            when kConfig < nHid {
                umbrales@push(0.05)
            } otherwise {
                umbrales@push(0.0)
            }
            mascaraActiva@push(0)
            indicesActivosPrev@push(0)
            hipSlotCortical@push(0.0)
        }

        change mediaHabituacion: List of[Float] = List[]
        mediaHabituacion@reserve(nIn)
        change hipSlotSensorial: List of[Float] = List[]
        hipSlotSensorial@reserve(nIn)
        each j among 0..nIn {
            mediaHabituacion@push(0.0)
            hipSlotSensorial@push(0.0)
        }

        change bOut: List of[Float] = List[]
        bOut@reserve(nOut)
        each o among 0..nOut {
            bOut@push(0.0)
        }

        give EncaSistemaCognitivo(
            nIn: nIn,
            nHid: nHid,
            kActivas: kConfig,
            nOut: nOut,
            entrenarInternos: entrenarInt,
            usarHipocampo: activarHipocampo,
            wIn: wIn,
            wRec: wRec,
            wBind: wBind,
            wOut: wOut,
            bHid: bHid,
            bOut: bOut,
            bRetro: bRetro,
            alphas: alphas,
            mediaHabituacion: mediaHabituacion,
            vMem: vMem,
            sAct: sAct,
            sPrev: sPrev,
            umbrales: umbrales,
            mascaraActiva: mascaraActiva,
            indicesActivosPrev: indicesActivosPrev,
            numActivasPrev: 0,
            hipSlotSensorial: hipSlotSensorial,
            hipSlotCortical: hipSlotCortical,
            hipOcupado: 0,
            filtroIn: filtroIn,
            filtroRec: filtroRec,
            trazaIn: trazaIn,
            trazaRec: trazaRec,
            eventosDisparados: 0,
            escriturasHipocampo: 0,
            pasosEjecutados: 0,
            macsEjecutadas: 0,
            macsDensasRef: 0,
            maxPotencialObs: 0.0
        )
    }

    exclusive flow reiniciarEpisodio() {
        each i among 0..this.nHid {
            this.vMem[i] = 0.0
            this.sAct[i] = 0.0
            this.sPrev[i] = 0.0
            this.mascaraActiva[i] = 0
            this.indicesActivosPrev[i] = 0
            this.hipSlotCortical[i] = 0.0
        }
        this.numActivasPrev = 0
        this.hipOcupado = 0

        each j among 0..this.nIn {
            this.mediaHabituacion[j] = 0.0
            this.hipSlotSensorial[j] = 0.0
        }

        each i among 0..(this.nHid * this.nIn) {
            this.filtroIn[i] = 0.0
            this.trazaIn[i] = 0.0
        }
        each i among 0..(this.nHid * this.nHid) {
            this.filtroRec[i] = 0.0
            this.trazaRec[i] = 0.0
        }
    }

    // Paso temporal con habituación talámica, compuerta de novedad y memoria hipocampal
    exclusive flow pasoTemporal(entrada: view [Float], acumularTrazas: Bool) {
        hold gammaTraza = 0.90
        hold umbralEvento = 0.08

        this.pasosEjecutados += 1
        this.macsDensasRef += (this.nHid * this.nIn) + (this.nHid * this.nHid)

        // 1. Compactar índices activos previos
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

        // 2. Filtro Talámico de Habituación Rápida (suprime distractores repetidos)
        change errHab: [Float; 4] = [0.0, 0.0, 0.0, 0.0]
        change novedadInformativa = 0.0
        each j among 0..this.nIn {
            when this.usarHipocampo {
                errHab[j] = entrada[j] - this.mediaHabituacion[j]
                // Habituación rápida en el canal distractor (j=2)
                when j == 2 {
                    this.mediaHabituacion[j] = 0.35 * this.mediaHabituacion[j] + 0.65 * entrada[j]
                } otherwise {
                    this.mediaHabituacion[j] = 0.85 * this.mediaHabituacion[j] + 0.15 * entrada[j]
                }
            } otherwise {
                errHab[j] = entrada[j]
            }
            when j != 2 {
                novedadInformativa += absFloat(errHab[j])
            }
        }

        // Compuerta colinérgica g(t): protege el estado cortical durante pasos de ruido
        change compuertaG = 1.0
        when this.usarHipocampo {
            when novedadInformativa < 0.25 {
                compuertaG = 0.03
            }
        }

        hold esConsultaCue = entrada[3] > 0.5

        // 3. Integración de membrana y Binding Cortico-Hipocampal en el paso Cue
        each i among 0..this.nHid {
            hold alphaBase = this.alphas[i]
            hold alphaEff = 1.0 - compuertaG * (1.0 - alphaBase)
            change u = this.bHid[i]

            each j among 0..this.nIn {
                when absFloat(errHab[j]) > umbralEvento {
                    u += this.wIn[i * this.nIn + j] * errHab[j]
                    this.macsEjecutadas += 1
                }
            }

            each idxAct among 0..this.numActivasPrev {
                hold r = this.indicesActivosPrev[idxAct]
                u += this.wRec[i * this.nHid + r] * this.sPrev[r]
                this.macsEjecutadas += 1
            }

            // Recuperación Asociativa desde el Hipocampo cuando llega la señal Cue
            when this.usarHipocampo && esConsultaCue && (this.hipOcupado == 1) {
                hold difBit0 = this.hipSlotSensorial[0] - entrada[0]
                hold difBit1 = this.hipSlotSensorial[1] - entrada[1]
                hold energiaDiferencia = absFloat(difBit0) + absFloat(difBit1)
                // Señal de coincidencia (+1 si el recuerdo y el estímulo actual coinciden, -1 si difieren)
                hold coincidenciaEpisodica = 1.0 - energiaDiferencia
                u += this.wBind[i * this.nIn + 0] * coincidenciaEpisodica + 0.35 * this.hipSlotCortical[i]
                this.macsEjecutadas += 2
            }

            hold nuevoV = alphaEff * this.vMem[i] + (1.0 - alphaEff) * u
            this.vMem[i] = nuevoV
            hold absV = absFloat(nuevoV)
            when absV > this.maxPotencialObs {
                this.maxPotencialObs = absV
            }
            this.mascaraActiva[i] = 0
        }

        // 4. Competición lateral Top-K Winners-Take-All (k-WTA)
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

        // 5. Escritura One-Shot en Hipocampo si hay alta novedad informativa previa al Cue
        when this.usarHipocampo && (!esConsultaCue) && (novedadInformativa > 0.60) && (this.hipOcupado == 0) {
            each j among 0..this.nIn {
                this.hipSlotSensorial[j] = entrada[j]
            }
            each i among 0..this.nHid {
                this.hipSlotCortical[i] = this.sAct[i]
            }
            this.hipOcupado = 1
            this.escriturasHipocampo += 1
        }

        // 6. Actualización de trazas de elegibilidad locales y homeostasis
        each i among 0..this.nHid {
            hold alphaI = this.alphas[i]
            hold activa = this.mascaraActiva[i]

            when this.kActivas < this.nHid {
                when activa == 1 {
                    this.umbrales[i] = clampFloat(this.umbrales[i] + 0.0015 * 0.75, 0.01, 0.45)
                } otherwise {
                    this.umbrales[i] = clampFloat(this.umbrales[i] - 0.0015 * 0.25, 0.01, 0.45)
                }
            }

            when acumularTrazas {
                hold vI = this.vMem[i]
                hold thv = tanhFloat(vI)
                change psi = 1.0 - (thv * thv)
                when psi < 0.05 {
                    psi = 0.05
                }

                each j among 0..this.nIn {
                    hold idxIn = i * this.nIn + j
                    hold fIn = alphaI * this.filtroIn[idxIn] + (1.0 - alphaI) * errHab[j]
                    this.filtroIn[idxIn] = fIn
                    this.trazaIn[idxIn] = gammaTraza * this.trazaIn[idxIn] + psi * fIn
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

    // Decisión y actualización sináptica local de 3 factores
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
            hold decay = 0.0002

            when this.entrenarInternos {
                each i among 0..this.nHid {
                    hold errProyectado = this.bRetro[0 * this.nHid + i] * deltaOut[0] + this.bRetro[1 * this.nHid + i] * deltaOut[1]
                    hold senalLocal = modulador * errProyectado

                    each j among 0..this.nIn {
                        hold idxIn = i * this.nIn + j
                        hold gradIn = clampFloat(senalLocal * this.trazaIn[idxIn], -1.0, 1.0)
                        this.wIn[idxIn] -= lr * (gradIn + decay * this.wIn[idxIn])
                        this.wBind[idxIn] -= lr * (senalLocal * this.sAct[i] + decay * this.wBind[idxIn])
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

// --- 4. PROTOCOLO EXPERIMENTAL ENCA-EXP-002 (RETARDOS D = 2, 4, 8, 16) ---

flow ejecutarEpisodioXor(
    modelo: edit EncaSistemaCognitivo,
    rngRuido: edit Rng,
    b1: Int,
    b2: Int,
    retardoD: Int,
    lr: Float,
    entrenar: Bool,
    sorpresaEpisodio: edit Float
) => Int {
    modelo@reiniciarEpisodio()

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

flow evaluarSistema(
    nombreModelo: Text,
    semilla: Int,
    retardoD: Int,
    kActivas: Int,
    entrenarInternos: Bool,
    usarHipocampo: Bool
) {
    change modelo = EncaSistemaCognitivo@crear(semilla, kActivas, entrenarInternos, usarHipocampo)
    change rngTrain = Rng@nuevo(semilla + 500)
    change rngTest = Rng@nuevo(semilla + 9000)

    hold epocas = 80
    hold lr = 0.075
    change sorpresaTemp = 0.0

    each epoca among 1..=epocas {
        hold c00 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 0, 0, retardoD, lr, true, edit sorpresaTemp)
        hold c01 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 0, 1, retardoD, lr, true, edit sorpresaTemp)
        hold c10 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 1, 0, retardoD, lr, true, edit sorpresaTemp)
        hold c11 = ejecutarEpisodioXor(edit modelo, edit rngTrain, 1, 1, retardoD, lr, true, edit sorpresaTemp)
    }

    modelo.eventosDisparados = 0
    modelo.escriturasHipocampo = 0
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

    hold totalOportunidades = modelo.pasosEjecutados * modelo.nHid
    hold unidadesSilentes = totalOportunidades - modelo.eventosDisparados
    hold normaW = modelo@normaFrobeniusPesos()

    print("[{nombreModelo} | Semilla={semilla} | Retardo D={retardoD}]")
    print("  -> Aciertos Test (sobre 40): {aciertosTest} | Sorpresa acumulada: {sumaSorpresaTest}")
    print("  -> Silentes: {unidadesSilentes}/{totalOportunidades} | Escrituras Hipocampo: {modelo.escriturasHipocampo} | MACs: {modelo.macsEjecutadas} (Ref Densa: {modelo.macsDensasRef})")
    print("  -> Estabilidad: Max |v_i|={modelo.maxPotencialObs} | ||W||_F={normaW}")
}

flow main() => Int {
    print("======================================================================")
    print("ELE NEUROLAB — EXPERIMENTO ENCA-EXP-002 (CORTEZA + HIPOCAMPO EPISÓDICO)")
    print("======================================================================")

    print("--- 1. COMPARATIVA EN RETARDO LARGO D=8 (SEMILLA=101) ---")
    evaluarSistema("BASELINE-RESERVOIR (k=16, Sin Hipocampo)", 101, 8, 16, false, false)
    evaluarSistema("BASELINE-RNN-DENSA (k=16, Sin Hipocampo)", 101, 8, 16, true, false)
    evaluarSistema("ENCA-FASE3 (k=4 + Hipocampo Episodico)", 101, 8, 4, true, true)

    print("--- 2. EVALUACION MULTI-SEMILLA Y MULTI-RETARDO ENCA-FASE3 (D=2, 4, 8, 16) ---")
    hold semillas: [Int; 3] = [101, 202, 303]
    hold retardos: [Int; 4] = [2, 4, 8, 16]

    each s among semillas {
        each d among retardos {
            evaluarSistema("ENCA-FASE3", s, d, 4, true, true)
        }
    }

    give 0
}