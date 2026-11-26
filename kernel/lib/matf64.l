// Matemática de referencia en f64 (Float) e impresión de Float.
//
// exp: reducción x = k·ln2 + r con |r| <= ln2/2 (ln2 partido en una parte
// alta exacta y una baja) y serie de Taylor hasta r^14; 2^k se arma con los
// bits del exponente. log: x = 2^e·m con m en [sqrt(1/2), sqrt(2)) y
// log m = 2·atanh((m-1)/(m+1)) en serie hasta s^25. Errores del orden de
// 1e-16 relativo: sirven de referencia para las versiones f32 con SSE.

take nucleo.cpu
take nucleo.mem
take lib.consola

fixed LN2_ALTO = 0.6931471803691238
fixed LN2_BAJO = 0.00000000019082149292705877
fixed INV_LN2 = 1.4426950408889634
fixed RAIZ2 = 1.4142135623730951

expose flow absF(x: Float) => Float {
    when x < 0.0 { give 0.0 - x }
    give x
}

// 2^k como Float (k entero en -1022..1023).
expose flow potencia2(k: Int) => Float {
    give floatDeBits((k + 1023) << 52)
}

expose flow expF(x: Float) => Float {
    when x > 709.0 { give potencia2(1023) * 2.0 }
    when x < -745.0 { give 0.0 }
    change kf = x * INV_LN2
    change k = 0
    when kf >= 0.0 { k = Int(kf + 0.5) } otherwise { k = Int(kf - 0.5) }
    hold r = (x - Float(k) * LN2_ALTO) - Float(k) * LN2_BAJO
    change termino = 1.0
    change suma = 1.0
    each n among 1..15 {
        termino = termino * r / Float(n)
        suma = suma + termino
    }
    // 2^k en dos mitades para no salir del rango de exponentes.
    hold k1 = k / 2
    give suma * potencia2(k1) * potencia2(k - k1)
}

expose flow logF(x: Float) => Float {
    when x <= 0.0 { give -1000000.0 }
    hold bits = bitsDeFloat(x)
    change e = ((bits >> 52) & 0x7FF) - 1023
    change m = floatDeBits((bits & 0x000FFFFFFFFFFFFF) | 0x3FF0000000000000)
    when m > RAIZ2 {
        m = m / 2.0
        e += 1
    }
    hold s = (m - 1.0) / (m + 1.0)
    hold s2 = s * s
    change potencia = s
    change suma = 0.0
    change n = 1
    during n <= 25 {
        suma = suma + potencia / Float(n)
        potencia = potencia * s2
        n += 2
    }
    give Float(e) * (LN2_ALTO + LN2_BAJO) + 2.0 * suma
}

// exp(x) - 1 sin cancelación cerca de 0.
expose flow expm1F(x: Float) => Float {
    when absF(x) > 0.5 { give expF(x) - 1.0 }
    change termino = x
    change suma = x
    each n among 2..20 {
        termino = termino * x / Float(n)
        suma = suma + termino
    }
    give suma
}

expose flow tanhF(x: Float) => Float {
    when x > 20.0 { give 1.0 }
    when x < -20.0 { give -1.0 }
    hold e = expm1F(2.0 * x)
    give e / (e + 2.0)
}

expose flow raizF64(x: Float) => Float {
    when x <= 0.0 { give 0.0 }
    give raizF(x)
}

// Imprime x en notación científica con `cifras` decimales: -1,2345e-07.
expose flow kprintCientifico(x: Float, cifras: Int) {
    change v = x
    when v < 0.0 {
        kprintByte(45)
        v = 0.0 - v
    }
    when v == 0.0 {
        kprintByte(48)
        give
    }
    change exponente = 0
    during v >= 10.0 {
        v = v / 10.0
        exponente += 1
    }
    during v < 1.0 {
        v = v * 10.0
        exponente -= 1
    }
    change escala = 1
    each i among 0..cifras { escala = escala * 10 }
    change mantisa = Int(v * Float(escala) + 0.5)
    when mantisa >= 10 * escala {
        mantisa = mantisa / 10
        exponente += 1
    }
    kprintEntero(mantisa / escala)
    when cifras > 0 {
        kprintByte(44)
        hold fraccion = mantisa % escala
        change divisor = escala / 10
        during divisor > 0 {
            kprintByte(48 + (fraccion / divisor) % 10)
            divisor = divisor / 10
        }
    }
    kprintByte(101)
    when exponente < 0 {
        kprintByte(45)
        exponente = 0 - exponente
    } otherwise {
        kprintByte(43)
    }
    when exponente < 10 { kprintByte(48) }
    kprintEntero(exponente)
}
