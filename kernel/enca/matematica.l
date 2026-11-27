// ENCA en el kernel: matemática del modelo (port literal de math_utils.l y
// lnRapido). Mismas constantes y mismo orden de operaciones que en Windows:
// de ello depende la reproducción exacta bit a bit.

take nucleo.cpu
take nucleo.mem
take mem.monton

expose flow maxFloat(a: Float, b: Float) => Float {
    when a > b { give a }
    give b
}

expose flow clampFloat(x: Float, minVal: Float, maxVal: Float) => Float {
    when x < minVal { give minVal }
    when x > maxVal { give maxVal }
    give x
}

expose flow expFloat(x: Float) => Float {
    hold reduced = clampFloat(x, -16.0, 16.0) * 0.0625
    hold x2 = reduced * reduced
    hold x3 = x2 * reduced
    hold x4 = x3 * reduced
    hold x5 = x4 * reduced
    change result = 1.0 + reduced + x2 * 0.5 + x3 / 6.0 + x4 / 24.0 + x5 / 120.0
    result = result * result
    result = result * result
    result = result * result
    result = result * result
    give result
}

expose flow lnFloat(x: Float) => Float {
    change reduced = maxFloat(x, 0.0000001)
    change exponent = 0.0
    during reduced > 2.0 {
        reduced = reduced * 0.5
        exponent += 1.0
    }
    during reduced < 0.5 {
        reduced = reduced * 2.0
        exponent -= 1.0
    }
    hold z = (reduced - 1.0) / (reduced + 1.0)
    hold z2 = z * z
    hold z4 = z2 * z2
    hold series = z * (1.0 + z2 / 3.0 + z4 / 5.0 + z4 * z2 / 7.0)
    give 2.0 * series + exponent * 0.69314718056
}

flow digitToFloat(digit: Int) => Float {
    when digit == 1 { give 1.0 }
    when digit == 2 { give 2.0 }
    when digit == 3 { give 3.0 }
    when digit == 4 { give 4.0 }
    when digit == 5 { give 5.0 }
    when digit == 6 { give 6.0 }
    when digit == 7 { give 7.0 }
    when digit == 8 { give 8.0 }
    when digit == 9 { give 9.0 }
    give 0.0
}

expose flow intToFloat(value: Int) => Float {
    change remaining = value
    change sign = 1.0
    when remaining < 0 { sign = -1.0 }
    change place = 1.0
    change result = 0.0
    during remaining != 0 {
        change digit = remaining % 10
        when digit < 0 { digit = 0 - digit }
        result += digitToFloat(digit) * place
        place *= 10.0
        remaining = remaining / 10
    }
    give sign * result
}

// ln(x) con reducción gruesa (factor 2^16) antes de la serie.
expose flow lnRapido(x: Float) => Float {
    change reducido = maxFloat(x, 1.0e-30)
    change exponente = 0.0
    during reducido < 0.0000152587890625 {
        reducido = reducido * 65536.0
        exponente -= 16.0
    }
    during reducido < 0.5 {
        reducido = reducido * 2.0
        exponente -= 1.0
    }
    during reducido > 2.0 {
        reducido = reducido * 0.5
        exponente += 1.0
    }
    hold z = (reducido - 1.0) / (reducido + 1.0)
    hold z2 = z * z
    hold z4 = z2 * z2
    hold serie = z * (1.0 + z2 / 3.0 + z4 / 5.0 + z4 * z2 / 7.0)
    give 2.0 * serie + exponente * 0.69314718056
}

// Acceso a arreglos de Float de 8 bytes por elemento.
expose flow lf(dir: Int) => Float { give floatDeBits(leer64(dir)) }
expose flow ef(dir: Int, v: Float) { escribir64(dir, bitsDeFloat(v)) }

// Reserva de ENCA: todo sale del montón al iniciar y se cuenta aquí (sin
// reservas durante el entrenamiento). Devuelve 0 si no hay memoria.
flow contadorReservas() => Int { give reservar(8, 8) }

// Rastro de reservas (solo el barrido de ranuras lo activa): +0 activo,
// +8 cuántas, +16 (puntero, bytes) x 512. Permite devolver TODO lo de un
// modelo al montón aunque algunas direcciones se hayan alineado después.
flow rastro() => Int { give reservar(16 + 512 * 16, 8) }

expose flow ncaRastrear(activo: Bool) {
    hold r = rastro()
    escribir64(r + 8, 0)
    when activo { escribir64(r, 1) } otherwise { escribir64(r, 0) }
}

expose flow ncaReservar(bytes: Int) => Int {
    hold p = montonReservar(bytes)
    when p != 0 {
        escribir64(contadorReservas(), leer64(contadorReservas()) + bytes)
        hold r = rastro()
        when leer64(r) == 1 {
            hold n = leer64(r + 8)
            when n < 512 {
                escribir64(r + 16 + n * 16, p)
                escribir64(r + 24 + n * 16, bytes)
                escribir64(r + 8, n + 1)
            } otherwise {
                escribir64(r, 2)
            }
        }
    }
    give p
}

// Libera todo lo reservado con el rastro activo; devuelve cuántos bloques, o
// -1 si el rastro se desbordó (hubo reservas sin anotar).
expose flow ncaLiberarRastreado() => Int {
    hold r = rastro()
    hold n = leer64(r + 8)
    hold completo = leer64(r) == 1
    each i among 0..n {
        montonLiberar(leer64(r + 16 + i * 16))
        escribir64(contadorReservas(), leer64(contadorReservas()) - leer64(r + 24 + i * 16))
    }
    escribir64(r, 0)
    escribir64(r + 8, 0)
    when !completo { give -1 }
    give n
}

// Reserva alineada a 64 bytes (para SSE y líneas de caché); 0 si no hay memoria.
expose flow ncaReservarAlineado(bytes: Int) => Int {
    hold p = ncaReservar(bytes + 64)
    when p == 0 { give 0 }
    give (p + 63) & (~63)
}

// Libera un bloque pedido con ncaReservar (`bytes` = lo pedido).
expose flow ncaLiberar(p: Int, bytes: Int) {
    when p != 0 {
        montonLiberar(p)
        escribir64(contadorReservas(), leer64(contadorReservas()) - bytes)
    }
}

expose flow ncaBytesReservados() => Int { give leer64(contadorReservas()) }
