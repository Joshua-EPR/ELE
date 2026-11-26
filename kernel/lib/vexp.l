// exp y tanh vectorizadas con SSE (4 floats f32 por paso), sin AVX/FMA.
//
// exp (método de Cephes): x se acota a [-88,38; 88,38]; n = redondeo(x·log2 e)
// (CVTPS2DQ); r = x - n·C1 - n·C2 con ln 2 = C1 + C2 partido para que n·C1
// sea exacto; exp(r) ≈ 1 + r + r²·P(r) con P de grado 5 (coeficientes de
// Cephes expf); 2^n se arma sumando n + 127 al exponente (PADDD + PSLLD 23).
//
// tanh: |x| >= 1/16: 1 - 2/(exp(2|x|) + 1) (2|x| acotado a 18); |x| < 1/16:
// x - x³/3 + 2x⁵/15. Se elige con una máscara (CMPPS) y se recupera el
// signo con AND/OR de bits.
//
// Usan XMM1..XMM15 sin Float de por medio.

take nucleo.cpu
take nucleo.mem
take lib.consola
take lib.matf64
take dispositivos.apic

// Constantes f32 (una por palabra de 8 bytes; ver el comentario de cabecera).
flow k() => Int {
    give datos64(0x42B0C0A5, 0xC2B0C0A5, 0x3FB8AA3B, 0x3F318000, 0xB95E8083, 0x39506967, 0x3AB743CE, 0x3C088908, 0x3D2AA9C1, 0x3E2AAAAA, 0x3F000000, 0x3F800000, 0x40000000, 0x41900000, 0x3E088889, 0xBEAAAAAB, 0x3D800000, 0x7F, 0x7FFFFFFF, 0x80000000)
}

// Tabla de constantes de vexp/vtanh (para código que usa expRegistro).
expose flow vexpConstantes() => Int { give k() }

// exp de los 4 floats de XMM1; deja el resultado en XMM8 (usa 2..9).
expose flow expRegistro(c: Int) {
    xmmDifundirEn(2, c, 0)
    xmmMinimo(1, 2)
    xmmDifundirEn(2, c, 8)
    xmmMaximo(1, 2)
    xmmDifundirEn(3, c, 16)
    xmmCopiar(4, 1)
    xmmMultiplicar(4, 3)
    xmmAEnteros(5, 4)
    xmmAFlotantes(6, 5)
    xmmDifundirEn(3, c, 24)
    xmmCopiar(7, 6)
    xmmMultiplicar(7, 3)
    xmmRestar(1, 7)
    xmmDifundirEn(3, c, 32)
    xmmCopiar(7, 6)
    xmmMultiplicar(7, 3)
    xmmRestar(1, 7)
    xmmDifundirEn(8, c, 40)
    xmmMultiplicar(8, 1)
    xmmDifundirEn(3, c, 48)
    xmmSumar(8, 3)
    xmmMultiplicar(8, 1)
    xmmDifundirEn(3, c, 56)
    xmmSumar(8, 3)
    xmmMultiplicar(8, 1)
    xmmDifundirEn(3, c, 64)
    xmmSumar(8, 3)
    xmmMultiplicar(8, 1)
    xmmDifundirEn(3, c, 72)
    xmmSumar(8, 3)
    xmmMultiplicar(8, 1)
    xmmDifundirEn(3, c, 80)
    xmmSumar(8, 3)
    xmmCopiar(9, 1)
    xmmMultiplicar(9, 1)
    xmmMultiplicar(8, 9)
    xmmSumar(8, 1)
    xmmDifundirEn(3, c, 88)
    xmmSumar(8, 3)
    xmmDifundirEn(3, c, 136)
    xmmSumarEnteros(5, 3)
    xmmDesplazarIzq(5, 23)
    xmmMultiplicar(8, 5)
}

// y[i] = exp(x[i]), n múltiplo de 4, búferes alineados a 16.
expose flow vexp(x: Int, y: Int, n: Int) {
    hold c = k()
    change p = 0
    hold bytes = n * 4
    during p < bytes {
        xmmCargar(1, x + p)
        expRegistro(c)
        xmmGuardar(y + p, 8)
        p += 16
    }
}

expose flow vtanh(x: Int, y: Int, n: Int) {
    hold c = k()
    change p = 0
    hold bytes = n * 4
    during p < bytes {
        xmmCargar(1, x + p)
        // |x| en 10 y el signo en 11.
        xmmDifundirEn(2, c, 144)
        xmmCopiar(10, 1)
        xmmY(10, 2)
        xmmDifundirEn(2, c, 152)
        xmmCopiar(11, 1)
        xmmY(11, 2)
        // Grande: 1 - 2/(exp(2|x|) + 1), con 2|x| <= 18.
        xmmCopiar(1, 10)
        xmmSumar(1, 10)
        xmmDifundirEn(2, c, 104)
        xmmMinimo(1, 2)
        expRegistro(c)
        xmmDifundirEn(3, c, 88)
        xmmSumar(8, 3)
        xmmDifundirEn(4, c, 96)
        xmmDividir(4, 8)
        xmmDifundirEn(12, c, 88)
        xmmRestar(12, 4)
        // Pequeño: |x|·(1 + x²·(-1/3 + x²·2/15)).
        xmmCopiar(13, 10)
        xmmMultiplicar(13, 10)
        xmmDifundirEn(14, c, 112)
        xmmMultiplicar(14, 13)
        xmmDifundirEn(2, c, 120)
        xmmSumar(14, 2)
        xmmMultiplicar(14, 13)
        xmmDifundirEn(2, c, 88)
        xmmSumar(14, 2)
        xmmMultiplicar(14, 10)
        // Máscara |x| < 1/16 y mezcla; después el signo.
        xmmCopiar(15, 10)
        xmmDifundirEn(2, c, 128)
        xmmComparar(15, 2, 1)
        xmmCopiar(2, 15)
        xmmY(2, 14)
        xmmYNo(15, 12)
        xmmO(15, 2)
        xmmO(15, 11)
        xmmGuardar(y + p, 15)
        p += 16
    }
}

// Mide exp (en [-87, 88]) y tanh (en [-10, 10]) sobre `total` valores
// equiespaciados contra expF/tanhF en f64. Devuelve true si los errores
// están dentro de lo esperado para f32 (exp: < 4 ulp relativos; tanh:
// error absoluto < 4e-7).
expose flow vexpMedir(pedidos: Int) => Bool {
    hold lote = 4096
    change total = pedidos
    hold inicio = rdtsc()
    hold x = reservar(16384, 64)
    hold y = reservar(16384, 64)
    change peor_exp = 0.0
    change peor_tanh_abs = 0.0
    change peor_tanh_rel = 0.0
    change ciclos_exp = 0
    change ciclos_tanh = 0
    change hecho = 0
    during hecho < total {
        // exp
        each i among 0..lote {
            hold v = -87.0 + 175.0 * Float(hecho + i) / Float(total)
            escribirF32(x + i * 4, v)
        }
        hold t0 = rdtsc()
        vexp(x, y, lote)
        ciclos_exp += rdtsc() - t0
        each i among 0..lote {
            hold ref = expF(leerF32(x + i * 4))
            hold err = absF(leerF32(y + i * 4) - ref) / ref
            when err > peor_exp { peor_exp = err }
        }
        // tanh
        each i among 0..lote {
            hold v = -10.0 + 20.0 * Float(hecho + i) / Float(total)
            escribirF32(x + i * 4, v)
        }
        hold t1 = rdtsc()
        vtanh(x, y, lote)
        ciclos_tanh += rdtsc() - t1
        each i among 0..lote {
            hold xv = leerF32(x + i * 4)
            hold ref = tanhF(xv)
            hold err = absF(leerF32(y + i * 4) - ref)
            when err > peor_tanh_abs { peor_tanh_abs = err }
            when absF(ref) > 0.0 {
                hold rel = err / absF(ref)
                when rel > peor_tanh_rel { peor_tanh_rel = rel }
            }
        }
        hecho += lote
        // En un equipo lento (emulación) se mide menos.
        when hecho == lote && total > 65536 && rdtsc() - inicio > 50 * tscCiclosPorMs() {
            total = 65536
            kprintln(cadena("  (equipo lento: se miden 65536 valores)"))
        }
    }
    hold ulp = 0.000000059604644775390625
    kprint(cadena("exp SSE: "))
    kprintEntero(total)
    kprint(cadena(" valores en [-87, 88], error relativo máximo "))
    kprintCientifico(peor_exp, 2)
    kprint(cadena(" ("))
    kprintCientifico(peor_exp / ulp, 2)
    kprint(cadena(" ulp), "))
    kprintEntero(ciclos_exp * 100 / total)
    kprintln(cadena(" centésimas de ciclo por valor"))
    kprint(cadena("tanh SSE: en [-10, 10], error absoluto máximo "))
    kprintCientifico(peor_tanh_abs, 2)
    kprint(cadena(", relativo "))
    kprintCientifico(peor_tanh_rel, 2)
    kprint(cadena(", "))
    kprintEntero(ciclos_tanh * 100 / total)
    kprintln(cadena(" centésimas de ciclo por valor"))
    give peor_exp < 4.0 * ulp && peor_tanh_abs < 0.0000004
}
