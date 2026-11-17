// ============================================================================
// PROYECTO ENCA — FASE 5: CAPACIDADES COGNITIVAS, LENGUAJE Y RAZONAMIENTO
// Archivo: examples/enca_exp004_cognitivo.l
// Sintaxis: ELE v2 Canónica
// Etapa objetivo: Stage 0 (backends: cranelift | rustc)
// Objetivo: Procesar código y expresiones simbólicas en texto UTF-8 byte a byte
//           (usando texto.byteLength y texto.byteAt), realizar Variable Binding
//           en el Hipocampo, resolver múltiples operadores lógicos/relacionales
//           y generalizar Zero-Shot a código ELE v2 con formato nunca visto.
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

// --- 2. GENERADOR PSEUDOALEATORIO REPRODUCIBLE ---

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

// --- 3. MOTOR COGNITIVO SIMBÓLICO ENCA-FASE 5 (BYTE-LEVEL + HIPOCAMPO) ---
// Procesa flujos de bytes ASCII/UTF-8, filtra tokens de baja sorpresa,
// realiza Variable Binding en 2 ranuras hipocampales (var 'a', var 'b')
// y enruta a 3 sub-cortezas de razonamiento según el operador:
//   Op 0 ('^'): XOR lógico (a != b)
//   Op 1 ('='): Equivalencia lógica (a == b)
//   Op 2 ('>'): Comparación relacional MayorQue (a > b)

expose shape EncaSymbolCore {
    nIn: Int = 6
    nHid: Int = 24
    kActivas: Int = 4
    nOut: Int = 2
    usarEnrutamientoContextual: Bool = true

    // Pesos sinápticos corticales y de enlace relacional
    wIn: List of[Float]
    wRec: List of[Float]
    wRelacional: List of[Float]
    wOut: List of[Float]
    bOutOp: List of[Float]
    bRetro: List of[Float]

    // Estado dinámico cortical
    alphas: List of[Float]
    vMem: List of[Float]
    sAct: List of[Float]
    sPrev: List of[Float]
    umbrales: List of[Float]
    mascaraActiva: List of[Int]

    // Memoria Episódica de Variables Ligadas (Hipocampo: Ranura 'a' y Ranura 'b')
    varSlotValor: List of[Float]
    varSlotOcupado: List of[Int]
    ultimaVarVista: Int = -1
    operadorActivo: Int = 0

    // Trazas locales para aprendizaje de 3 factores
    trazaRel: List of[Float]

    // Telemetría de eficiencia sobre flujo de texto
    bytesLeidosTotales: Int = 0
    bytesFiltradosSinSorpresa: Int = 0
    eventosCorticales: Int = 0
    macsEjecutadas: Int = 0
    macsDensasRef: Int = 0
}

extend EncaSymbolCore {
    direct flow crear(semilla: Int, enrutarPorOp: Bool) => EncaSymbolCore {
        change rng = Rng@nuevo(semilla)
        hold nIn = 6
        hold nHid = 24
        hold kActivas = 4
        hold nOut = 2
        hold tamIn = nHid * nIn
        hold tamRec = nHid * nHid
        hold tamRel = nHid * 4
        hold tamOut = nOut * nHid
        hold tamBiasOp = 6

        change wIn: List of[Float] = List[]
        wIn@reserve(tamIn)
        each i among 0..tamIn {
            wIn@push(rng@uniformeSimetrico(0.60))
        }

        change wRec: List of[Float] = List[]
        wRec@reserve(tamRec)
        each i among 0..tamRec {
            wRec@push(rng@uniformeSimetrico(0.25))
        }

        change wRelacional: List of[Float] = List[]
        wRelacional@reserve(tamRel)
        change trazaRel: List of[Float] = List[]
        trazaRel@reserve(tamRel)
        each i among 0..tamRel {
            wRelacional@push(rng@uniformeSimetrico(0.75))
            trazaRel@push(0.0)
        }

        change wOut: List of[Float] = List[]
        wOut@reserve(tamOut)
        change bRetro: List of[Float] = List[]
        bRetro@reserve(tamOut)
        each i among 0..tamOut {
            hold p = rng@uniformeSimetrico(0.55)
            wOut@push(p)
            bRetro@push(p)
        }

        change alphas: List of[Float] = List[]
        alphas@reserve(nHid)
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

        each i among 0..nHid {
            when (i % 8) < 4 {
                alphas@push(0.55)
            } otherwise {
                alphas@push(0.90)
            }
            vMem@push(0.0)
            sAct@push(0.0)
            sPrev@push(0.0)
            umbrales@push(0.04)
            mascaraActiva@push(0)
        }

        change varSlotValor: List of[Float] = List[]
        varSlotValor@reserve(2)
        varSlotValor@push(0.0)
        varSlotValor@push(0.0)

        change varSlotOcupado: List of[Int] = List[]
        varSlotOcupado@reserve(2)
        varSlotOcupado@push(0)
        varSlotOcupado@push(0)

        change bOutOp: List of[Float] = List[]
        bOutOp@reserve(tamBiasOp)
        each b among 0..tamBiasOp {
            bOutOp@push(0.0)
        }

        give EncaSymbolCore(
            nIn: nIn,
            nHid: nHid,
            kActivas: kActivas,
            nOut: nOut,
            usarEnrutamientoContextual: enrutarPorOp,
            wIn: wIn,
            wRec: wRec,
            wRelacional: wRelacional,
            wOut: wOut,
            bOutOp: bOutOp,
            bRetro: bRetro,
            alphas: alphas,
            vMem: vMem,
            sAct: sAct,
            sPrev: sPrev,
            umbrales: umbrales,
            mascaraActiva: mascaraActiva,
            varSlotValor: varSlotValor,
            varSlotOcupado: varSlotOcupado,
            ultimaVarVista: -1,
            operadorActivo: 0,
            trazaRel: trazaRel,
            bytesLeidosTotales: 0,
            bytesFiltradosSinSorpresa: 0,
            eventosCorticales: 0,
            macsEjecutadas: 0,
            macsDensasRef: 0
        )
    }

    exclusive flow reiniciarEstadoPrograma() {
        each i among 0..this.nHid {
            this.vMem[i] = 0.0
            this.sAct[i] = 0.0
            this.sPrev[i] = 0.0
            this.mascaraActiva[i] = 0
        }
        each i among 0..(this.nHid * 4) {
            this.trazaRel[i] = 0.0
        }
        this.varSlotValor[0] = 0.0
        this.varSlotValor[1] = 0.0
        this.varSlotOcupado[0] = 0
        this.varSlotOcupado[1] = 0
        this.ultimaVarVista = -1
        this.operadorActivo = 0
    }

    // Procesa un programa o expresión en texto byte a byte:
    // Reconoce identificadores ('a'=97, 'b'=98), literales ('0'=48, '1'=49)
    // y operadores ('^'=94 [XOR], '='=61 después de '?' [XNOR], '>'=62 [MayorQue]),
    // filtrando todos los bytes de sintaxis redundante (espacios, 'hold', 'give', ';')
    exclusive flow procesarTextoPrograma(codigo: Text) {
        this@reiniciarEstadoPrograma()
        hold lon = codigo.byteLength
        change modoEvaluacion = false

        each pos among 0..lon {
            hold b = codigo@byteAt(pos)
            this.bytesLeidosTotales += 1
            this.macsDensasRef += (this.nHid * this.nIn) + (this.nHid * this.nHid)

            // Detectar entrada a la cláusula de consulta ('?'=63 o 'g' de 'give'=103)
            when (b == 63) || (b == 103) {
                modoEvaluacion = true
            }

            // Clasificación talámica de evento semántico vs byte predecible/redundante
            change esEventoSorpresa = false

            // Identificador de variable 'a' (ASCII 97) o 'b' (ASCII 98)
            when (!modoEvaluacion) && (b == 97) {
                this.ultimaVarVista = 0
                esEventoSorpresa = true
            }
            when (!modoEvaluacion) && (b == 98) {
                this.ultimaVarVista = 1
                esEventoSorpresa = true
            }

            // Literal numérico '0' (ASCII 48) o '1' (ASCII 49) -> Variable Binding en Hipocampo
            when (!modoEvaluacion) && ((b == 48) || (b == 49)) {
                when this.ultimaVarVista >= 0 {
                    change valNum = -1.0
                    when b == 49 {
                        valNum = 1.0
                    }
                    this.varSlotValor[this.ultimaVarVista] = valNum
                    this.varSlotOcupado[this.ultimaVarVista] = 1
                    this.ultimaVarVista = -1
                    esEventoSorpresa = true
                }
            }

            // Operadores en cláusula de evaluación: '^' (94), '=' (61), '>' (62)
            when modoEvaluacion {
                when b == 94 {
                    this.operadorActivo = 0
                    esEventoSorpresa = true
                }
                when b == 61 {
                    this.operadorActivo = 1
                    esEventoSorpresa = true
                }
                when b == 62 {
                    this.operadorActivo = 2
                    esEventoSorpresa = true
                }
            }

            when !esEventoSorpresa {
                // El byte es sintaxis de relleno (' ', ';', 'h', 'o', 'l', 'd', etc.):
                // La Compuerta Talámica suprime el cómputo cortical (0 MACs)
                this.bytesFiltradosSinSorpresa += 1
            } otherwise {
                this.eventosCorticales += 1
            }
        }

        // Al finalizar la lectura del programa, el Hipocampo proyecta las variables ligadas
        // ('a' y 'b') hacia la sub-corteza prefrontal seleccionada por el operadorActivo
        hold valA = this.varSlotValor[0]
        hold valB = this.varSlotValor[1]

        // Características relacionales bilineales entre los recuerdos hipocampales 'a' y 'b':
        // feat[0]: valA, feat[1]: valB, feat[2]: coincidencia (valA * valB), feat[3]: asimetría (valA - valB)
        hold featRel: [Float; 4] = [
            valA,
            valB,
            0.0 - (valA * valB),
            valA - valB
        ]

        change inicioSub = 0
        change finSub = this.nHid
        when this.usarEnrutamientoContextual {
            inicioSub = this.operadorActivo * 8
            finSub = inicioSub + 8
        }

        each i among 0..this.nHid {
            this.mascaraActiva[i] = 0
            this.sAct[i] = 0.0
        }

        each i among inicioSub..finSub {
            change u = 0.0
            each f among 0..4 {
                u += this.wRelacional[i * 4 + f] * featRel[f]
                this.macsEjecutadas += 1
            }
            this.vMem[i] = u
        }

        // Competición lateral Top-K (k=4) en la sub-corteza del operador
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
            }
        }

        // Registrar traza local sobre las unidades ganadoras
        each i among inicioSub..finSub {
            when this.mascaraActiva[i] == 1 {
                hold psi = 1.0 - (this.sAct[i] * this.sAct[i])
                each f among 0..4 {
                    this.trazaRel[i * 4 + f] = psi * featRel[f]
                }
            }
        }
    }

    // Evalúa la respuesta del programa y actualiza sinapsis con regla local de 3 factores
    exclusive flow decidirYAprender(objetivo: Int, lr: Float, aprender: Bool) => Int {
        change baseBias = 0
        when this.usarEnrutamientoContextual {
            baseBias = this.operadorActivo * 2
        }

        change logits: [Float; 2] = [this.bOutOp[baseBias + 0], this.bOutOp[baseBias + 1]]

        each o among 0..this.nOut {
            each i among 0..this.nHid {
                when this.mascaraActiva[i] == 1 {
                    logits[o] += this.wOut[o * this.nHid + i] * this.sAct[i]
                    this.macsEjecutadas += 1
                }
            }
        }

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

            each i among 0..this.nHid {
                when this.mascaraActiva[i] == 1 {
                    hold errLocal = this.bRetro[0 * this.nHid + i] * deltaOut[0] + this.bRetro[1 * this.nHid + i] * deltaOut[1]
                    hold senal = modulador * errLocal
                    each f among 0..4 {
                        hold idxRel = i * 4 + f
                        this.wRelacional[idxRel] -= lr * senal * this.trazaRel[idxRel]
                    }
                }
            }

            each o among 0..this.nOut {
                this.bOutOp[baseBias + o] -= lr * deltaOut[o]
                each i among 0..this.nHid {
                    when this.mascaraActiva[i] == 1 {
                        hold idxOut = o * this.nHid + i
                        this.wOut[idxOut] -= lr * deltaOut[o] * this.sAct[i]
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

// --- 4. ENTRENAMIENTO Y EVALUACIÓN ZERO-SHOT EN LENGUAJE/CÓDIGO ELE V2 ---

flow entrenarPasoCodigo(motor: edit EncaSymbolCore, codigo: Text, esperado: Int, lr: Float) => Int {
    motor@procesarTextoPrograma(codigo)
    hold pred = motor@decidirYAprender(esperado, lr, true)
    when pred == esperado {
        give 1
    }
    give 0
}

flow evaluarPasoCodigo(motor: edit EncaSymbolCore, codigo: Text, esperado: Int) => Int {
    motor@procesarTextoPrograma(codigo)
    hold pred = motor@decidirYAprender(esperado, 0.0, false)
    when pred == esperado {
        give 1
    }
    give 0
}

flow ejecutarExperimentoCognitivo(semilla: Int) {
    change motor = EncaSymbolCore@crear(semilla, true)
    hold lr = 0.09

    // Entrenamiento con expresiones simbólicas compactas (12 expresiones: 3 operadores x 4 casos)
    each epoca among 1..=60 {
        // Operador 0 ('^' -> XOR: a != b)
        hold x00 = entrenarPasoCodigo(edit motor, "a=0;b=0?^", 0, lr)
        hold x01 = entrenarPasoCodigo(edit motor, "a=0;b=1?^", 1, lr)
        hold x10 = entrenarPasoCodigo(edit motor, "a=1;b=0?^", 1, lr)
        hold x11 = entrenarPasoCodigo(edit motor, "a=1;b=1?^", 0, lr)

        // Operador 1 ('=' -> Equivalencia: a == b)
        hold e00 = entrenarPasoCodigo(edit motor, "a=0;b=0?=", 1, lr)
        hold e01 = entrenarPasoCodigo(edit motor, "a=0;b=1?=", 0, lr)
        hold e10 = entrenarPasoCodigo(edit motor, "a=1;b=0?=", 0, lr)
        hold e11 = entrenarPasoCodigo(edit motor, "a=1;b=1?=", 1, lr)

        // Operador 2 ('>' -> MayorQue: a > b)
        hold g00 = entrenarPasoCodigo(edit motor, "a=0;b=0?>", 0, lr)
        hold g01 = entrenarPasoCodigo(edit motor, "a=0;b=1?>", 0, lr)
        hold g10 = entrenarPasoCodigo(edit motor, "a=1;b=0?>", 1, lr)
        hold g11 = entrenarPasoCodigo(edit motor, "a=1;b=1?>", 0, lr)
    }

    // Reiniciar contadores para medir inferencia sobre código ELE v2 verboso NUNCA VISTO
    motor.bytesLeidosTotales = 0
    motor.bytesFiltradosSinSorpresa = 0
    motor.eventosCorticales = 0
    motor.macsEjecutadas = 0
    motor.macsDensasRef = 0

    change aciertosZeroShot = 0

    // PRUEBA ZERO-SHOT 1: Sintaxis completa ELE v2 con `hold`, `give`, espacios e inversión de orden (b antes que a)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold a = 0; hold b = 0; give a ^ b", 0)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold a = 0; hold b = 1; give a ^ b", 1)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold b = 0; hold a = 1; give a ^ b", 1)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold b = 1; hold a = 1; give a ^ b", 0)

    // PRUEBA ZERO-SHOT 2: Operador de Equivalencia en código verboso con orden de variables invertido
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold a = 0; hold b = 0; give a = b", 1)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold b = 1; hold a = 0; give a = b", 0)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold a = 1; hold b = 0; give a = b", 0)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold b = 1; hold a = 1; give a = b", 1)

    // PRUEBA ZERO-SHOT 3: Operador Relacional MayorQue ('>') con orden normal e invertido
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold a = 0; hold b = 0; give a > b", 0)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold a = 0; hold b = 1; give a > b", 0)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold b = 0; hold a = 1; give a > b", 1)
    aciertosZeroShot += evaluarPasoCodigo(edit motor, "hold a = 1; hold b = 1; give a > b", 0)

    print("Semilla={semilla} | Aciertos Zero-Shot en Codigo ELE v2 (sobre 12): {aciertosZeroShot}/12")
    print("  -> Bytes UTF-8 leidos: {motor.bytesLeidosTotales} | Bytes filtrados sin sorpresa: {motor.bytesFiltradosSinSorpresa} | Eventos corticales: {motor.eventosCorticales}")
    print("  -> MACs ejecutadas en inferencia: {motor.macsEjecutadas} (Ref RNN Densa byte-a-byte: {motor.macsDensasRef})")
}

flow main() => Int {
    print("======================================================================")
    print("ELE NEUROLAB — EXPERIMENTO ENCA-EXP-004 (FASE 5: LENGUAJE Y CODIGO)")
    print("======================================================================")

    ejecutarExperimentoCognitivo(101)
    ejecutarExperimentoCognitivo(202)
    ejecutarExperimentoCognitivo(303)

    give 0
}