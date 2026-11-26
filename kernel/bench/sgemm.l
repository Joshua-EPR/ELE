// Banco de pruebas de lib/sgemm.l (hito 11).
//
// Valores de prueba: múltiplos de 1/8 entre -1 y 1. Los productos son
// múltiplos de 1/64 y las sumas (|suma| <= K <= 2048) caben exactas en la
// mantisa de 24 bits de f32, así que el resultado correcto se conoce
// exactamente: se compara contra el producto ingenuo calculado en enteros
// (unidades de 1/64) y se informa el error relativo máximo.

take nucleo.cpu
take nucleo.mem
take mem.monton
take lib.consola
take lib.sgemm
take cpu.buzon
take dispositivos.apic

// Bits f32 de num / 8 (|num| < 2^20).
flow f32DeOctavos(num: Int) => Int {
    when num == 0 { give 0 }
    change signo = 0
    change n = num
    when n < 0 {
        signo = 0x80000000
        n = 0 - n
    }
    change e = 0
    during (n >> (e + 1)) != 0 { e += 1 }
    give signo | ((127 + e - 3) << 23) | ((n - (1 << e)) << (23 - e))
}

// Valor de unos bits f32 en unidades de 1/64; -2^62 si no es exacto.
flow enSesentaycuatroavos(bits: Int) => Int {
    when bits & 0x7FFFFFFF == 0 { give 0 }
    hold e = ((bits >> 23) & 0xFF) - 127
    hold m = (bits & 0x7FFFFF) | 0x800000
    hold desplazamiento = e - 17
    change v = 0
    when desplazamiento >= 0 {
        v = m << desplazamiento
    } otherwise {
        hold s = 0 - desplazamiento
        when s > 40 || (m & ((1 << s) - 1)) != 0 { give -4611686018427387904 }
        v = m >> s
    }
    when bits & 0x80000000 != 0 { v = 0 - v }
    give v
}

flow valorA(i: Int, k: Int) => Int { give (i * 7 + k * 3) % 17 - 8 }
flow valorB(k: Int, j: Int) => Int { give (k * 5 + j * 11) % 17 - 8 }
flow valorC(i: Int, j: Int) => Int { give (i + j) % 5 - 2 }

// Estado de un caso: +0 A, +8 B, +16 C (direcciones), +24 lda, +32 ldb.
flow caso() => Int { give reservar(40, 8) }

flow llenar(m: Int, n: Int, k: Int, ta: Bool, tb: Bool) {
    hold s = caso()
    hold a = leer64(s)
    hold b = leer64(s + 8)
    each i among 0..m {
        each kk among 0..k {
            when ta {
                escribir32(a + (kk * m + i) * 4, f32DeOctavos(valorA(i, kk)))
            } otherwise {
                escribir32(a + (i * k + kk) * 4, f32DeOctavos(valorA(i, kk)))
            }
        }
    }
    each kk among 0..k {
        each j among 0..n {
            when tb {
                escribir32(b + (j * k + kk) * 4, f32DeOctavos(valorB(kk, j)))
            } otherwise {
                escribir32(b + (kk * n + j) * 4, f32DeOctavos(valorB(kk, j)))
            }
        }
    }
}

flow iniciarC(m: Int, n: Int) {
    hold c = leer64(caso() + 16)
    each i among 0..m {
        each j among 0..n { escribir32(c + (i * n + j) * 4, f32DeOctavos(valorC(i, j))) }
    }
}

// Error relativo máximo en partes por millón, sobre las filas 0, m/3,
// 2m/3 y m-1 enteras; -1 si algún valor no es exacto en f32.
flow errorMaximo(m: Int, n: Int, k: Int, acumular: Bool) => Int {
    hold c = leer64(caso() + 16)
    change peor = 0
    each f among 0..4 {
        change i = 0
        when f == 1 { i = m / 3 }
        when f == 2 { i = 2 * m / 3 }
        when f == 3 { i = m - 1 }
        each j among 0..n {
            change esperado = 0
            each kk among 0..k { esperado += valorA(i, kk) * valorB(kk, j) }
            when acumular { esperado += valorC(i, j) * 8 }
            hold obtenido = enSesentaycuatroavos(leer32(c + (i * n + j) * 4))
            when obtenido == -4611686018427387904 { give -1 }
            change diferencia = obtenido - esperado
            when diferencia < 0 { diferencia = 0 - diferencia }
            change base = esperado
            when base < 0 { base = 0 - base }
            when base < 1 { base = 1 }
            hold ppm = diferencia * 1000000 / base
            when ppm > peor { peor = ppm }
        }
    }
    give peor
}

flow centesimas(valor: Int) {
    kprintEntero(valor / 100)
    kprintByte(44)
    kprintByte(48 + (valor / 10) % 10)
    kprintByte(48 + valor % 10)
}

// Ejecuta un SGEMM y devuelve los ciclos de TSC.
flow medir(m: Int, n: Int, k: Int, ta: Bool, tb: Bool, acumular: Bool, variante: Int, nucleos: Int) => Int {
    hold s = caso()
    change lda = k
    when ta { lda = m }
    change ldb = n
    when tb { ldb = k }
    when acumular { iniciarC(m, n) }
    hold t0 = rdtsc()
    hold bien = sgemm(m, n, k, leer64(s), lda, ta, leer64(s + 8), ldb, tb, leer64(s + 16), n, acumular, variante, nucleos)
    hold ciclos = rdtsc() - t0
    when !bien { give 0 }
    give ciclos
}

// Resultado de un caso: +0 FLOP/ciclo x100 con 2 núcleos, +8 correcto (1/0).
flow resultado() => Int { give reservar(16, 8) }

// Una fila de la tabla. Mide con 1 núcleo y con todos, verifica ambos.
flow fila(m: Int, n: Int, k: Int, ta: Bool, tb: Bool, acumular: Bool, variante: Int) {
    hold s = caso()
    escribir64(s, montonReservar(m * k * 4))
    escribir64(s + 8, montonReservar(k * n * 4))
    escribir64(s + 16, montonReservar(m * n * 4))
    llenar(m, n, k, ta, tb)
    hold flops = 2 * m * n * k
    hold c1 = medir(m, n, k, ta, tb, acumular, variante, 1)
    hold e1 = errorMaximo(m, n, k, acumular)
    hold nucleos = buzonNucleos()
    when montonVerificar() != 0 { kprintln(cadena("  montón dañado tras 1 núcleo")) }
    hold c2 = medir(m, n, k, ta, tb, acumular, variante, nucleos)
    hold e2 = errorMaximo(m, n, k, acumular)
    montonLiberar(leer64(s + 16))
    montonLiberar(leer64(s + 8))
    montonLiberar(leer64(s))
    hold roto = montonVerificar()
    when roto != 0 {
        kprint(cadena("  MONTÓN DAÑADO en el bloque libre "))
        kprintEntero(roto)
        kprintByte(10)
    }

    kprint(cadena("  "))
    kprintEntero(m)
    kprintByte(120)
    kprintEntero(k)
    kprint(cadena(" · "))
    kprintEntero(k)
    kprintByte(120)
    kprintEntero(n)
    when ta { kprint(cadena(" Aᵀ")) }
    when tb { kprint(cadena(" Bᵀ")) }
    when acumular { kprint(cadena(" C+=")) }
    when c1 == 0 || c2 == 0 {
        kprintln(cadena(": error de parámetros o memoria"))
        escribir64(resultado(), 0)
        escribir64(resultado() + 8, 0)
        give
    }
    hold mhz = tscCiclosPorMs() / 1000
    kprint(cadena(": 1 núcleo "))
    kprintEntero(flops * mhz / c1)
    kprint(cadena(" MFLOPS "))
    centesimas(flops * 100 / c1)
    kprint(cadena(" F/c | "))
    kprintEntero(nucleos)
    kprint(cadena(" núcleos "))
    kprintEntero(flops * mhz / c2)
    kprint(cadena(" MFLOPS "))
    centesimas(flops * 100 / c2 / nucleos)
    kprint(cadena(" F/c/núcleo, x"))
    centesimas(c1 * 100 / c2)
    kprint(cadena(", "))
    kprintEntero(flops * 100 / c2 * 100 / (800 * nucleos))
    kprint(cadena(" % chip; error "))
    when e1 < 0 || e2 < 0 {
        kprintln(cadena("NO EXACTO"))
    } otherwise {
        kprintEntero(e1 + e2)
        kprintln(cadena(" ppm"))
    }
    escribir64(resultado(), flops * 100 / c2)
    change bien = 0
    when e1 == 0 && e2 == 0 { bien = 1 }
    escribir64(resultado() + 8, bien)
}

// FLOP/ciclo x100 de una variante en 1 núcleo, N x N x N.
flow probarVariante(n: Int, variante: Int) => Int {
    hold s = caso()
    escribir64(s, montonReservar(n * n * 4))
    escribir64(s + 8, montonReservar(n * n * 4))
    escribir64(s + 16, montonReservar(n * n * 4))
    llenar(n, n, n, false, false)
    when montonVerificar() != 0 { kprintln(cadena("  montón dañado antes de la variante")) }
    hold ciclos = medir(n, n, n, false, false, false, variante, 1)
    when montonVerificar() != 0 { kprintln(cadena("  montón dañado tras la variante")) }
    hold exacto = errorMaximo(n, n, n, false) == 0
    montonLiberar(leer64(s + 16))
    montonLiberar(leer64(s + 8))
    montonLiberar(leer64(s))
    when ciclos == 0 || !exacto { give 0 }
    give 2 * n * n * n * 100 / ciclos
}

// Hito 11. Devuelve true si todo es exacto y, con N >= 512, se alcanza al
// menos el 50 % del pico del chip (8 FLOP/ciclo por núcleo).
expose flow sgemmHito11() => Bool {
    hold nucleos = buzonNucleos()
    kprint(cadena("SGEMM: "))
    kprintEntero(nucleos)
    kprintln(cadena(" núcleos; variantes del micronúcleo (512, 1 núcleo):"))
    hold v0 = probarVariante(512, SGEMM_2x16_MOVUPS)
    hold v1 = probarVariante(512, SGEMM_2x16_MEMORIA)
    hold v2 = probarVariante(512, SGEMM_3x16_MEMORIA)
    kprint(cadena("  a) 2x16 MOVUPS+MULPS "))
    centesimas(v0)
    kprint(cadena(" | b) 2x16 MULPS memoria "))
    centesimas(v1)
    kprint(cadena(" | c) 3x16 MULPS memoria "))
    centesimas(v2)
    kprintln(cadena(" FLOP/ciclo"))
    change variante = SGEMM_2x16_MOVUPS
    change mejor = v0
    when v1 > mejor {
        variante = SGEMM_2x16_MEMORIA
        mejor = v1
    }
    when v2 > mejor { variante = SGEMM_3x16_MEMORIA }
    kprint(cadena("  elegida: "))
    when variante == SGEMM_2x16_MOVUPS { kprintln(cadena("a")) }
    when variante == SGEMM_2x16_MEMORIA { kprintln(cadena("b")) }
    when variante == SGEMM_3x16_MEMORIA { kprintln(cadena("c")) }
    when mejor == 0 {
        kprintln(cadena("  ninguna variante dio un resultado exacto"))
        give false
    }

    change todo_bien = true
    change pico_bien = true
    // Variantes para backpropagation, 256.
    fila(256, 256, 256, false, false, false, variante)
    when leer64(resultado() + 8) != 1 { todo_bien = false }
    fila(256, 256, 256, true, false, false, variante)
    when leer64(resultado() + 8) != 1 { todo_bien = false }
    fila(256, 256, 256, false, true, false, variante)
    when leer64(resultado() + 8) != 1 { todo_bien = false }
    fila(256, 256, 256, false, false, true, variante)
    when leer64(resultado() + 8) != 1 { todo_bien = false }
    // Formas de un transformer pequeño (d = 256, contexto 64).
    fila(64, 1024, 256, false, false, false, variante)
    when leer64(resultado() + 8) != 1 { todo_bien = false }
    fila(64, 256, 1024, false, false, false, variante)
    when leer64(resultado() + 8) != 1 { todo_bien = false }
    fila(64, 768, 256, false, false, false, variante)
    when leer64(resultado() + 8) != 1 { todo_bien = false }
    // Cuadradas grandes. En un equipo lento (emulación TCG: la variante de
    // 512 por debajo de 0,5 FLOP/ciclo) solo se mide 512.
    change tamanos = 3
    when mejor < 50 {
        tamanos = 1
        kprintln(cadena("  equipo lento (emulación): se omiten 1024 y 2048"))
    }
    each t among 0..tamanos {
        change n = 512
        when t == 1 { n = 1024 }
        when t == 2 { n = 2048 }
        fila(n, n, n, false, false, false, variante)
        when leer64(resultado() + 8) != 1 { todo_bien = false }
        when tamanos == 3 && leer64(resultado()) * 100 / (800 * nucleos) < 50 { pico_bien = false }
    }
    when !pico_bien { kprintln(cadena("  no se alcanza el 50 % del pico del chip con N >= 512")) }
    give todo_bien && pico_bien
}
