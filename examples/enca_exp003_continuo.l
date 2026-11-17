// ============================================================================
// PROYECTO ENCA — FASE 4 (REV 2): APRENDIZAJE CONTINUO SIN INTERFERENCIA
// Archivo: examples/enca_exp003_continuo.l
// Sintaxis: ELE v2 Canónica
// Etapa objetivo: Stage 0 (backends: cranelift | rustc)
// Objetivo: Alcanzar >= 95-100% (40/40) simultáneamente en Tarea A (XOR) y
//           Tarea B (XNOR opuesta) mediante partición cortical prefrontal,
//           consolidación sináptica selectiva, Sleep Replay y Rollback.
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

// --- 3. CHECKPOINT VERSIONADO PARA REVERSIÓN SEGURA (SECCIÓN 10) ---

expose shape EncaCheckpoint {
    versionId: Int = 0
    wInSnap: List of[Float]
    wRecSnap: List of[Float]
    wBindSnap: List of[Float]
    wOutSnap: List of[Float]
    bOutSnap: List of[Float]
}

extend EncaCheckpoint {
    direct flow crearVacio(tamIn: Int, tamRec: Int, tamOut: Int, tamBiasOut: Int) => EncaCheckpoint {
        change wInSnap: List of[Float] = List[]
        wInSnap@reserve(tamIn)
        each i among 0..tamIn { wInSnap@push(0.0) }

        change wRecSnap: List of[Float] = List[]
        wRecSnap@reserve(tamRec)
        each i among 0..tamRec { wRecSnap@push(0.0) }

        change wBindSnap: List of[Float] = List[]
        wBindSnap@reserve(tamIn)
        each i among 0..tamIn { wBindSnap@push(0.0) }

        change wOutSnap: List of[Float] = List[]
        wOutSnap@reserve(tamOut)
        each i among 0..tamOut { wOutSnap@push(0.0) }

        change bOutSnap: List of[Float] = List[]
        bOutSnap@reserve(tamBiasOut)
        each i among 0..tamBiasOut { bOutSnap@push(0.0) }

        give EncaCheckpoint(
            versionId: 0,
            wInSnap: wInSnap,
            wRecSnap: wRecSnap,
            wBindSnap: wBindSnap,
            wOutSnap: wOutSnap,
            bOutSnap: bOutSnap
        )
    }
}

// --- 4. ARQUITECTURA ENCA-CONTINUAL V2 (PARTICIÓN PREFRONTAL + REPLAY) ---
// nIn = 5 canales: [Bit0, Bit1, Distractor, CueDecision, ContextoTarea]
// nHid = 16 microcolumnas: Sub-corteza A (0..7) y Sub-corteza B (8..15)

expose shape EncaContinual {
    nIn: Int = 5
    nHid: Int = 16
    kActivas: Int = 4
    nOut: Int = 2
    usarConsolidacion: Bool = true
    ctxActual: Int = 0

    // Pesos sinápticos activos
    wIn: List of[Float]
    wRec: List of[Float]
    wBind: List of[Float]
    wOut: List of[Float]
    bHid: List of[Float]
    // Sesgos de salida desacoplados por contexto [ctx * nOut + o] (4 elementos)
    bOutCtx: List of[Float]
    bRetro: List of[Float]

    // Anclas de consolidación e importancia por unidad cortical
    wInAncla: List of[Float]
    wBindAncla: List of[Float]
    wOutAncla: List of[Float]
    unidadConsolidada: List of[Float]

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

    // Memoria Episódica Rápida (Hipocampo)
    hipSlotSensorial: List of[Float]
    hipSlotCortical: List of[Float]
    hipOcupado: Int = 0

    // Filtros y trazas de elegibilidad locales
    filtroIn: List of[Float]
    filtroRec: List of[Float]
    trazaIn: List of[Float]
    trazaRec: List of[Float]

    // Telemetría
    eventosDisparados: Int = 0
    pasosEjecutados: Int = 0
    macsEjecutadas: Int = 0
    macsDensasRef: Int = 0
    ciclosSuenoReplay: Int = 0
}

extend EncaContinual {
    direct flow crear(semilla: Int, kConfig: Int, activarConsolidacion: Bool) => EncaContinual {
        change rng = Rng@nuevo(semilla)
        hold nIn = 5
        hold nHid = 16
        hold nOut = 2
        hold tamIn = nHid * nIn
        hold tamRec = nHid * nHid
        hold tamOut = nOut * nHid
        hold tamBiasCtx = 4

        change wIn: List of[Float] = List[]
        wIn@reserve(tamIn)
        change wBind: List of[Float] = List[]
        wBind@reserve(tamIn)
        change wInAncla: List of[Float] = List[]
        wInAncla@reserve(tamIn)
        change wBindAncla: List of[Float] = List[]
        wBindAncla@reserve(tamIn)
        change filtroIn: List of[Float] = List[]
        filtroIn@reserve(tamIn)
        change trazaIn: List of[Float] = List[]
        trazaIn@reserve(tamIn)

        each i among 0..tamIn {
            hold pIn = rng@uniformeSimetrico(0.70)
            hold pBind = rng@uniformeSimetrico(0.75)
            wIn@push(pIn)
            wBind@push(pBind)
            wInAncla@push(pIn)
            wBindAncla@push(pBind)
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
            wRec@push(rng@uniformeSimetrico(0.28))
            filtroRec@push(0.0)
            trazaRec@push(0.0)
        }

        change wOut: List of[Float] = List[]
        wOut@reserve(tamOut)
        change wOutAncla: List of[Float] = List[]
        wOutAncla@reserve(tamOut)
        change bRetro: List of[Float] = List[]
        bRetro@reserve(tamOut)

        each i among 0..tamOut {
            hold pOut = rng@uniformeSimetrico(0.55)
            wOut@push(pOut)
            wOutAncla@push(pOut)
            bRetro@push(pOut)
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
        change unidadConsolidada: List of[Float] = List[]
        unidadConsolidada@reserve(nHid)

        each i among 0..nHid {
            // Cada sub-corteza (0..7 y 8..15) tiene 4 unidades rápidas y 4 lentas
            when (i % 8) < 4 {
                alphas@push(0.60)
            } otherwise {
                alphas@push(0.92)
            }
            bHid@push(0.0)
            vMem@push(0.0)
            sAct@push(0.0)
            sPrev@push(0.0)
            umbrales@push(0.04)
            mascaraActiva@push(0)
            indicesActivosPrev@push(0)
            hipSlotCortical@push(0.0)
            unidadConsolidada@push(0.0)
        }

        change mediaHabituacion: List of[Float] = List[]
        mediaHabituacion@reserve(nIn)
        change hipSlotSensorial: List of[Float] = List[]
        hipSlotSensorial@reserve(nIn)
        each j among 0..nIn {
            mediaHabituacion@push(0.0)
            hipSlotSensorial@push(0.0)
        }

        change bOutCtx: List of[Float] = List[]
        bOutCtx@reserve(tamBiasCtx)
        each b among 0..tamBiasCtx {
            bOutCtx@push(0.0)
        }

        give EncaContinual(
            nIn: nIn,
            nHid: nHid,
            kActivas: kConfig,
            nOut: nOut,
            usarConsolidacion: activarConsolidacion,
            ctxActual: 0,
            wIn: wIn,
            wRec: wRec,
            wBind: wBind,
            wOut: wOut,
            bHid: bHid,
            bOutCtx: bOutCtx,
            bRetro: bRetro,
            wInAncla: wInAncla,
            wBindAncla: wBindAncla,
            wOutAncla: wOutAncla,
            unidadConsolidada: unidadConsolidada,
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
            pasosEjecutados: 0,
            macsEjecutadas: 0,
            macsDensasRef: 0,
            ciclosSuenoReplay: 0
        )
    }

    flow guardarCheckpoint(ckpt: edit EncaCheckpoint, nuevaVersion: Int) {
        ckpt.versionId = nuevaVersion
        each i among 0..(this.nHid * this.nIn) {
            ckpt.wInSnap[i] = this.wIn[i]
            ckpt.wBindSnap[i] = this.wBind[i]
        }
        each i among 0..(this.nHid * this.nHid) {
            ckpt.wRecSnap[i] = this.wRec[i]
        }
        each i among 0..(this.nOut * this.nHid) {
            ckpt.wOutSnap[i] = this.wOut[i]
        }
        each b among 0..4 {
            ckpt.bOutSnap[b] = this.bOutCtx[b]
        }
    }

    exclusive flow restaurarCheckpoint(ckpt: view EncaCheckpoint) {
        each i among 0..(this.nHid * this.nIn) {
            this.wIn[i] = ckpt.wInSnap[i]
            this.wBind[i] = ckpt.wBindSnap[i]
        }
        each i among 0..(this.nHid * this.nHid) {
            this.wRec[i] = ckpt.wRecSnap[i]
        }
        each i among 0..(this.nOut * this.nHid) {
            this.wOut[i] = ckpt.wOutSnap[i]
            this.bRetro[i] = ckpt.wOutSnap[i]
        }
        each b among 0..4 {
            this.bOutCtx[b] = ckpt.bOutSnap[b]
        }
    }

    // Consolida selectivamente el sub-espacio cortical de la tarea aprendida (idTarea = 0 -> unidades 0..7)
    exclusive flow consolidarSubCorteza(idTarea: Int) {
        change inicio = 0
        change fin = 8
        when idTarea == 1 {
            inicio = 8
            fin = 16
        }

        each i among inicio..fin {
            this.unidadConsolidada[i] = 1.0
            each j among 0..this.nIn {
                hold idxIn = i * this.nIn + j
                this.wInAncla[idxIn] = this.wIn[idxIn]
                this.wBindAncla[idxIn] = this.wBind[idxIn]
            }
            each o among 0..this.nOut {
                hold idxOut = o * this.nHid + i
                this.wOutAncla[idxOut] = this.wOut[idxOut]
            }
        }
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

    exclusive flow pasoTemporal(entrada: view [Float], acumularTrazas: Bool) {
        hold gammaTraza = 0.90
        hold umbralEvento = 0.08

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

        change errHab: [Float; 5] = [0.0, 0.0, 0.0, 0.0, 0.0]
        change novedadInformativa = 0.0
        each j among 0..this.nIn {
            errHab[j] = entrada[j] - this.mediaHabituacion[j]
            when j == 2 {
                this.mediaHabituacion[j] = 0.35 * this.mediaHabituacion[j] + 0.65 * entrada[j]
            } otherwise {
                when j == 4 {
                    errHab[j] = entrada[j]
                } otherwise {
                    this.mediaHabituacion[j] = 0.85 * this.mediaHabituacion[j] + 0.15 * entrada[j]
                }
            }
            when (j == 0) || (j == 1) || (j == 3) {
                novedadInformativa += absFloat(errHab[j])
            }
        }

        change compuertaG = 1.0
        when novedadInformativa < 0.25 {
            compuertaG = 0.03
        }

        hold esConsultaCue = entrada[3] > 0.5
        when entrada[4] > 0.5 {
            this.ctxActual = 1
        } otherwise {
            this.ctxActual = 0
        }

        // Selección del sub-espacio cortical activo según enrutamiento prefrontal
        change inicioSub = 0
        change finSub = this.nHid
        when this.usarConsolidacion {
            when this.ctxActual == 0 {
                inicioSub = 0
                finSub = 8
            } otherwise {
                inicioSub = 8
                finSub = 16
            }
        }

        each i among 0..this.nHid {
            this.mascaraActiva[i] = 0
        }

        // Integración de membrana SOLO en el sub-espacio cortical reclutado
        each i among inicioSub..finSub {
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

            when esConsultaCue && (this.hipOcupado == 1) {
                hold difBit0 = this.hipSlotSensorial[0] - entrada[0]
                hold difBit1 = this.hipSlotSensorial[1] - entrada[1]
                hold coincidencia = 1.0 - (absFloat(difBit0) + absFloat(difBit1))
                u += this.wBind[i * this.nIn + this.ctxActual] * coincidencia + 0.35 * this.hipSlotCortical[i]
                this.macsEjecutadas += 2
            }

            this.vMem[i] = alphaEff * this.vMem[i] + (1.0 - alphaEff) * u
        }

        // Competición lateral Top-K Winners-Take-All dentro del sub-espacio activo
        each turno among 0..this.kActivas {
            change mejorIdx = -1
            change mejorMargen = 0.0

            each i among inicioSub..finSub {
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

        // Escritura One-Shot en Hipocampo ante alta novedad previa al Cue
        when (!esConsultaCue) && (novedadInformativa > 0.60) && (this.hipOcupado == 0) {
            each j among 0..this.nIn {
                this.hipSlotSensorial[j] = entrada[j]
            }
            each i among 0..this.nHid {
                this.hipSlotCortical[i] = this.sAct[i]
            }
            this.hipOcupado = 1
        }

        // Actualización de trazas locales y homeostasis en el sub-espacio activo
        each i among inicioSub..finSub {
            hold alphaI = this.alphas[i]
            hold activa = this.mascaraActiva[i]

            when activa == 1 {
                this.umbrales[i] = clampFloat(this.umbrales[i] + 0.0015 * 0.50, 0.01, 0.40)
            } otherwise {
                this.umbrales[i] = clampFloat(this.umbrales[i] - 0.0015 * 0.50, 0.01, 0.40)
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
            }
        }
    }

    exclusive flow evaluarYAprender(objetivo: Int, lr: Float, aprender: Bool) => Int {
        change idxBiasBase = 0
        when this.usarConsolidacion && (this.ctxActual == 1) {
            idxBiasBase = 2
        }

        change logits: [Float; 2] = [this.bOutCtx[idxBiasBase + 0], this.bOutCtx[idxBiasBase + 1]]

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

        when aprender {
            change deltaOut: [Float; 2] = [probs[0], probs[1]]
            when objetivo == 0 {
                deltaOut[0] -= 1.0
            } otherwise {
                deltaOut[1] -= 1.0
            }

            hold modulador = clampFloat(0.5 + 0.4 * sorpresa, 0.5, 2.5)
            hold decay = 0.0002

            each i among 0..this.nHid {
                when this.mascaraActiva[i] == 1 {
                    // Si la unidad pertenece a una sub-corteza ya consolidada, aplica freno elástico fuerte
                    change rigidez = 0.0
                    when this.usarConsolidacion && (this.unidadConsolidada[i] > 0.5) {
                        rigidez = 0.85
                    }
                    hold plasticidadEfectiva = lr * (1.0 - rigidez)

                    hold errProy = this.bRetro[0 * this.nHid + i] * deltaOut[0] + this.bRetro[1 * this.nHid + i] * deltaOut[1]
                    hold senalLocal = modulador * errProy

                    each j among 0..this.nIn {
                        hold idxIn = i * this.nIn + j
                        hold gradIn = clampFloat(senalLocal * this.trazaIn[idxIn], -1.0, 1.0)
                        hold anclaIn = rigidez * (this.wIn[idxIn] - this.wInAncla[idxIn])
                        this.wIn[idxIn] -= plasticidadEfectiva * gradIn + lr * anclaIn
                    }

                    hold idxBindCtx = i * this.nIn + this.ctxActual
                    hold anclaBind = rigidez * (this.wBind[idxBindCtx] - this.wBindAncla[idxBindCtx])
                    this.wBind[idxBindCtx] -= plasticidadEfectiva * (senalLocal * this.sAct[i]) + lr * anclaBind
                }
            }

            each o among 0..this.nOut {
                this.bOutCtx[idxBiasBase + o] -= lr * deltaOut[o]
                each i among 0..this.nHid {
                    when this.mascaraActiva[i] == 1 {
                        change rigidezOut = 0.0
                        when this.usarConsolidacion && (this.unidadConsolidada[i] > 0.5) {
                            rigidezOut = 0.85
                        }
                        hold idxOut = o * this.nHid + i
                        hold anclaOut = rigidezOut * (this.wOut[idxOut] - this.wOutAncla[idxOut])
                        this.wOut[idxOut] -= lr * (1.0 - rigidezOut) * (deltaOut[o] * this.sAct[i] + decay * this.wOut[idxOut]) + lr * anclaOut
                        this.bRetro[idxOut] = this.wOut[idxOut]
                    }
                }
            }
        }

        when probs[1] > probs[0] {
            give 1
        }
        give 0
    }
}

// --- 5. PROTOCOLO EXPERIMENTAL MULTITAREA (TAREA A: XOR vs TAREA B: XNOR) ---

flow ejecutarEpisodioTarea(
    modelo: edit EncaContinual,
    rngRuido: edit Rng,
    idTarea: Int,
    b1: Int,
    b2: Int,
    retardoD: Int,
    lr: Float,
    entrenar: Bool
) => Int {
    modelo@reiniciarEpisodio()

    change ctxVal = 0.0
    when idTarea == 1 {
        ctxVal = 1.0
    }

    change vInicial: [Float; 5] = [
        rngRuido@uniformeSimetrico(0.02),
        rngRuido@uniformeSimetrico(0.02),
        rngRuido@uniformeSimetrico(0.02),
        0.0,
        ctxVal
    ]
    when b1 == 0 {
        vInicial[0] += 1.0
    } otherwise {
        vInicial[1] += 1.0
    }
    modelo@pasoTemporal(view vInicial, entrenar)

    each pasoRuido among 0..retardoD {
        hold vRuido: [Float; 5] = [
            rngRuido@uniformeSimetrico(0.02),
            rngRuido@uniformeSimetrico(0.02),
            1.0 + rngRuido@uniformeSimetrico(0.02),
            0.0,
            ctxVal
        ]
        modelo@pasoTemporal(view vRuido, entrenar)
    }

    change vConsulta: [Float; 5] = [
        rngRuido@uniformeSimetrico(0.02),
        rngRuido@uniformeSimetrico(0.02),
        0.0,
        1.0,
        ctxVal
    ]
    when b2 == 0 {
        vConsulta[0] += 1.0
    } otherwise {
        vConsulta[1] += 1.0
    }
    modelo@pasoTemporal(view vConsulta, entrenar)

    change etiqueta = 0
    when idTarea == 0 {
        when b1 != b2 {
            etiqueta = 1
        }
    } otherwise {
        when b1 == b2 {
            etiqueta = 1
        }
    }

    hold pred = modelo@evaluarYAprender(etiqueta, lr, entrenar)
    when pred == etiqueta {
        give 1
    }
    give 0
}

flow medirExactitudTarea(modelo: edit EncaContinual, idTarea: Int, retardoD: Int, semillaTest: Int) => Int {
    change rngTest = Rng@nuevo(semillaTest)
    change aciertos = 0
    each rep among 0..10 {
        aciertos += ejecutarEpisodioTarea(edit modelo, edit rngTest, idTarea, 0, 0, retardoD, 0.0, false)
        aciertos += ejecutarEpisodioTarea(edit modelo, edit rngTest, idTarea, 0, 1, retardoD, 0.0, false)
        aciertos += ejecutarEpisodioTarea(edit modelo, edit rngTest, idTarea, 1, 0, retardoD, 0.0, false)
        aciertos += ejecutarEpisodioTarea(edit modelo, edit rngTest, idTarea, 1, 1, retardoD, 0.0, false)
    }
    give aciertos
}

flow ejecutarExperimentoContinuo(semilla: Int, activarConsolidacionYReplay: Bool) {
    hold retardoD = 6
    hold lr = 0.085
    change modelo = EncaContinual@crear(semilla, 4, activarConsolidacionYReplay)
    change rngTrain = Rng@nuevo(semilla + 700)

    // FASE A: Entrenar exclusivamente en Tarea A (XOR Temporal)
    each epoca among 1..=75 {
        hold a00 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 0, 0, retardoD, lr, true)
        hold a01 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 0, 1, retardoD, lr, true)
        hold a10 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 1, 0, retardoD, lr, true)
        hold a11 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 1, 1, retardoD, lr, true)
    }

    hold accA_Fase1 = medirExactitudTarea(edit modelo, 0, retardoD, semilla + 5000)

    when activarConsolidacionYReplay {
        modelo@consolidarSubCorteza(0)
    }

    // FASE B: Entrenar en Tarea B (XNOR Temporal, opuesta a A)
    each epoca among 1..=75 {
        hold b00 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 1, 0, 0, retardoD, lr, true)
        hold b01 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 1, 0, 1, retardoD, lr, true)
        hold b10 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 1, 1, 0, retardoD, lr, true)
        hold b11 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 1, 1, 1, retardoD, lr, true)

        // Ciclo de Sueño (Offline Hippocampal Replay de Tarea A cada 5 épocas)
        when activarConsolidacionYReplay && ((epoca % 5) == 0) {
            modelo.ciclosSuenoReplay += 1
            hold r00 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 0, 0, 2, lr * 0.25, true)
            hold r01 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 0, 1, 2, lr * 0.25, true)
            hold r10 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 1, 0, 2, lr * 0.25, true)
            hold r11 = ejecutarEpisodioTarea(edit modelo, edit rngTrain, 0, 1, 1, 2, lr * 0.25, true)
        }
    }

    hold accA_Fase2 = medirExactitudTarea(edit modelo, 0, retardoD, semilla + 5000)
    hold accB_Fase2 = medirExactitudTarea(edit modelo, 1, retardoD, semilla + 6000)

    print("Semilla={semilla} | Tarea A (inicial): {accA_Fase1}/40 -> Retencion Tarea A: {accA_Fase2}/40 | Nueva Tarea B: {accB_Fase2}/40 | Replay={modelo.ciclosSuenoReplay}")
}

flow probarVersionadoYReversionCheckpoint(semilla: Int) {
    print("--- 3. PRUEBA DE CONTROL DE VERSIONES Y REVERSION DE CHECKPOINT (SECCION 10) ---")
    hold retardoD = 6
    change modelo = EncaContinual@crear(semilla, 4, true)
    change ckpt = EncaCheckpoint@crearVacio(modelo.nHid * modelo.nIn, modelo.nHid * modelo.nHid, modelo.nOut * modelo.nHid, 4)
    change rng = Rng@nuevo(semilla + 900)

    each epoca among 1..=75 {
        hold a00 = ejecutarEpisodioTarea(edit modelo, edit rng, 0, 0, 0, retardoD, 0.085, true)
        hold a01 = ejecutarEpisodioTarea(edit modelo, edit rng, 0, 0, 1, retardoD, 0.085, true)
        hold a10 = ejecutarEpisodioTarea(edit modelo, edit rng, 0, 1, 0, retardoD, 0.085, true)
        hold a11 = ejecutarEpisodioTarea(edit modelo, edit rng, 0, 1, 1, retardoD, 0.085, true)
    }

    hold accAntes = medirExactitudTarea(edit modelo, 0, retardoD, 8888)
    modelo@guardarCheckpoint(edit ckpt, 1)
    print("  [Checkpoint v{ckpt.versionId} guardado] Exactitud verificada pre-corrupcion: {accAntes}/40")

    modelo.usarConsolidacion = false
    each epocaCorrupta among 1..=25 {
        hold c00 = ejecutarEpisodioTarea(edit modelo, edit rng, 1, 0, 0, retardoD, 0.25, true)
        hold c01 = ejecutarEpisodioTarea(edit modelo, edit rng, 1, 0, 1, retardoD, 0.25, true)
        hold c10 = ejecutarEpisodioTarea(edit modelo, edit rng, 1, 1, 0, retardoD, 0.25, true)
        hold c11 = ejecutarEpisodioTarea(edit modelo, edit rng, 1, 1, 1, retardoD, 0.25, true)
    }

    hold accDegradada = medirExactitudTarea(edit modelo, 0, retardoD, 8888)
    print("  [Alerta de Regresion] Exactitud tras actualizacion no aprobada: {accDegradada}/40")

    when accDegradada < 36 {
        modelo@restaurarCheckpoint(view ckpt)
        modelo.usarConsolidacion = true
    }

    hold accRestaurada = medirExactitudTarea(edit modelo, 0, retardoD, 8888)
    print("  [Rollback Exitoso a Checkpoint v{ckpt.versionId}] Exactitud restaurada: {accRestaurada}/40")
}

flow main() => Int {
    print("======================================================================")
    print("ELE NEUROLAB — EXPERIMENTO ENCA-EXP-003 (FASE 4: APRENDIZAJE CONTINUO)")
    print("======================================================================")

    print("--- 1. DEMOSTRACION DE OLVIDO CATASTROFICO SIN CONSOLIDACION ---")
    ejecutarExperimentoContinuo(101, false)
    ejecutarExperimentoContinuo(202, false)

    print("--- 2. ENCA-CONTINUAL V2 (PARTICION PREFRONTAL + SLEEP REPLAY) ---")
    ejecutarExperimentoContinuo(101, true)
    ejecutarExperimentoContinuo(202, true)
    ejecutarExperimentoContinuo(303, true)

    probarVersionadoYReversionCheckpoint(101)

    give 0
}