// ENCA: memoria episódica secuencial de bytes (hipocampo predictivo), port
// literal de memoria_secuencial.l. Por orden n guarda, para el contexto
// hasheado de los últimos n bytes, hasta `ancho` sucesores con sus cuentas.
// Interpolación de órdenes con Witten-Bell:
//   p_n(c) = (cuenta_n(c) + d_n * p_{n-1}(c)) / (total_n + d_n)
//
// Bloque (2224 bytes; Float = 8 bytes con los bits IEEE):
//   +0 numOrdenes  +8 slots  +16 ancho
//   +24 etiquetas (Int, numOrdenes*slots)   +32 simbolos (Int, slots*orden*ancho)
//   +40 cuentas (Float, igual que simbolos) +48 totales (Float)   +56 distintos (Float)
//   +64 totalUnigrama (Float)   +72 ordenUsado   +80 sobrescrituras   +88 desalojos
//   +96 unigrama[256] (Float)   +2144 distribucion[256] (Float)   (fin: +4192)

take nucleo.cpu
take nucleo.mem
take enca.matematica

expose flow memCrear(numOrdenes: Int, slots: Int, ancho: Int) => Int {
    hold totalSlots = numOrdenes * slots
    hold totalEntradas = totalSlots * ancho
    hold m = ncaReservar(4192)
    hold etiquetas = ncaReservar(totalSlots * 8)
    hold totales = ncaReservar(totalSlots * 8)
    hold distintos = ncaReservar(totalSlots * 8)
    hold simbolos = ncaReservar(totalEntradas * 8)
    hold cuentas = ncaReservar(totalEntradas * 8)
    when m == 0 || etiquetas == 0 || totales == 0 || distintos == 0 || simbolos == 0 || cuentas == 0 { give 0 }
    escribir64(m, numOrdenes)
    escribir64(m + 8, slots)
    escribir64(m + 16, ancho)
    escribir64(m + 24, etiquetas)
    escribir64(m + 32, simbolos)
    escribir64(m + 40, cuentas)
    escribir64(m + 48, totales)
    escribir64(m + 56, distintos)
    escribir64(m + 64, bitsDeFloat(0.0))
    escribir64(m + 72, 0)
    escribir64(m + 80, 0)
    escribir64(m + 88, 0)
    each s among 0..totalSlots {
        escribir64(etiquetas + s * 8, -1)
        escribir64(totales + s * 8, 0)
        escribir64(distintos + s * 8, 0)
    }
    each e among 0..totalEntradas {
        escribir64(simbolos + e * 8, -1)
        escribir64(cuentas + e * 8, 0)
    }
    each c among 0..256 {
        escribir64(m + 96 + c * 8, 0)
        escribir64(m + 2144 + c * 8, 0)
    }
    give m
}

// Llena `distribucion` con p(siguiente byte | contextos); hashes = 5 Int.
expose flow memPredecir(m: Int, hashes: Int) {
    hold numOrdenes = leer64(m)
    hold slots = leer64(m + 8)
    hold ancho = leer64(m + 16)
    hold etiquetas = leer64(m + 24)
    hold simbolos = leer64(m + 32)
    hold cuentas = leer64(m + 40)
    hold totales = leer64(m + 48)
    hold distintosD = leer64(m + 56)
    hold unigrama = m + 96
    hold dist = m + 2144
    hold denominador = floatDeBits(leer64(m + 64)) + 256.0
    each c among 0..256 {
        escribir64(dist + c * 8, bitsDeFloat((floatDeBits(leer64(unigrama + c * 8)) + 1.0) / denominador))
    }
    escribir64(m + 72, 0)
    each nivel among 0..numOrdenes {
        hold hash = leer64(hashes + nivel * 8)
        hold slot = nivel * slots + hash % slots
        when leer64(etiquetas + slot * 8) == hash && floatDeBits(leer64(totales + slot * 8)) > 0.0 {
            hold total = floatDeBits(leer64(totales + slot * 8))
            hold distintos = floatDeBits(leer64(distintosD + slot * 8))
            hold escala = distintos / (total + distintos)
            hold inverso = 1.0 / (total + distintos)
            each c among 0..256 {
                escribir64(dist + c * 8, bitsDeFloat(floatDeBits(leer64(dist + c * 8)) * escala))
            }
            hold base = slot * ancho
            each e among 0..ancho {
                hold simbolo = leer64(simbolos + (base + e) * 8)
                when simbolo >= 0 {
                    escribir64(dist + simbolo * 8, bitsDeFloat(floatDeBits(leer64(dist + simbolo * 8)) + floatDeBits(leer64(cuentas + (base + e) * 8)) * inverso))
                }
            }
            escribir64(m + 72, nivel + 1)
        }
    }
}

// Registro one-shot del byte observado en todos los órdenes.
expose flow memAprender(m: Int, hashes: Int, byte: Int) {
    hold numOrdenes = leer64(m)
    hold slots = leer64(m + 8)
    hold ancho = leer64(m + 16)
    hold etiquetas = leer64(m + 24)
    hold simbolos = leer64(m + 32)
    hold cuentas = leer64(m + 40)
    hold totales = leer64(m + 48)
    hold distintosD = leer64(m + 56)
    hold unigrama = m + 96
    escribir64(unigrama + byte * 8, bitsDeFloat(floatDeBits(leer64(unigrama + byte * 8)) + 1.0))
    escribir64(m + 64, bitsDeFloat(floatDeBits(leer64(m + 64)) + 1.0))
    each nivel among 0..numOrdenes {
        hold hash = leer64(hashes + nivel * 8)
        hold slot = nivel * slots + hash % slots
        hold base = slot * ancho
        when leer64(etiquetas + slot * 8) != hash {
            when leer64(etiquetas + slot * 8) >= 0 { escribir64(m + 80, leer64(m + 80) + 1) }
            escribir64(etiquetas + slot * 8, hash)
            escribir64(totales + slot * 8, 0)
            escribir64(distintosD + slot * 8, 0)
            each e among 0..ancho {
                escribir64(simbolos + (base + e) * 8, -1)
                escribir64(cuentas + (base + e) * 8, 0)
            }
        }
        change encontrado = -1
        change libre = -1
        change menor = -1
        change menorCuenta = 1.0e30
        each e among 0..ancho {
            hold simbolo = leer64(simbolos + (base + e) * 8)
            when simbolo == byte { encontrado = e }
            when simbolo < 0 && libre < 0 { libre = e }
            when simbolo >= 0 && floatDeBits(leer64(cuentas + (base + e) * 8)) < menorCuenta {
                menorCuenta = floatDeBits(leer64(cuentas + (base + e) * 8))
                menor = e
            }
        }
        when encontrado >= 0 {
            escribir64(cuentas + (base + encontrado) * 8, bitsDeFloat(floatDeBits(leer64(cuentas + (base + encontrado) * 8)) + 1.0))
        } otherwise {
            when libre >= 0 {
                escribir64(simbolos + (base + libre) * 8, byte)
                escribir64(cuentas + (base + libre) * 8, bitsDeFloat(1.0))
                escribir64(distintosD + slot * 8, bitsDeFloat(floatDeBits(leer64(distintosD + slot * 8)) + 1.0))
            } otherwise {
                escribir64(totales + slot * 8, bitsDeFloat(floatDeBits(leer64(totales + slot * 8)) - menorCuenta))
                escribir64(simbolos + (base + menor) * 8, byte)
                escribir64(cuentas + (base + menor) * 8, bitsDeFloat(1.0))
                escribir64(m + 88, leer64(m + 88) + 1)
            }
        }
        escribir64(totales + slot * 8, bitsDeFloat(floatDeBits(leer64(totales + slot * 8)) + 1.0))
    }
}

// Misma fórmula que el original (aunque ENCA reserve algo distinto aquí).
expose flow memBytesReservados(m: Int) => Int {
    hold totalSlots = leer64(m) * leer64(m + 8)
    give (totalSlots * 3 + totalSlots * leer64(m + 16) * 2 + 512) * 8
}
