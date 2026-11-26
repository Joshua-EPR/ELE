// SGEMM C = A · B (f32, N x N, por filas) con SSE empaquetado: MULPS +
// ADDPS, sin FMA ni AVX (Celeron 3865U).
//
// Los acumuladores viven en registros XMM durante todo el bucle en k
// (ver `multiplicar`).
//
// El lenguaje aún no tiene un tipo f32: los valores de prueba son enteros
// pequeños cuyos bits f32 se calculan aquí, y el resultado se comprueba de
// forma exacta (todas las sumas son enteros < 2^24).

take nucleo.cpu
take nucleo.mem
take mem.monton
take lib.consola
take dispositivos.apic

// Bits f32 de un entero 0 <= n < 2^24.
flow f32DeEntero(n: Int) => Int {
    when n == 0 { give 0 }
    change e = 0
    during (n >> (e + 1)) != 0 { e += 1 }
    give ((127 + e) << 23) | ((n - (1 << e)) << (23 - e))
}

// Entero de unos bits f32 que representan un entero < 2^24.
flow enteroDeF32(bits: Int) => Int {
    when bits == 0 { give 0 }
    hold e = ((bits >> 23) & 0xFF) - 127
    hold m = (bits & 0x7FFFFF) | 0x800000
    give m >> (23 - e)
}

flow valorA(i: Int, k: Int) => Int { give (i + k) % 7 + 1 }
flow valorB(k: Int, j: Int) => Int { give (k * 3 + j) % 5 + 1 }

// Empaquetado (como en BLAS): B en paneles de 16 columnas, cada uno con
// las n filas seguidas (64 bytes por fila del panel); A en pares de filas
// intercalados (A[i][k], A[i+1][k]). Así los pasos dentro del micronúcleo
// son constantes y caben en el desplazamiento de las instrucciones.
flow empaquetar(a: Int, b: Int, ap: Int, bp: Int, n: Int) {
    hold fila = n * 4
    // B: cada fila de un panel son 16 floats seguidos = cuatro MOVUPS.
    change jb = 0
    during jb < n {
        change origen = b + jb * 4
        change destino = bp + jb * fila
        change k = 0
        during k < n {
            xmmCargar(6, origen)
            xmmCargar(7, origen +% 16)
            xmmCargar(8, origen +% 32)
            xmmCargar(9, origen +% 48)
            xmmGuardar(destino, 6)
            xmmGuardar(destino +% 16, 7)
            xmmGuardar(destino +% 32, 8)
            xmmGuardar(destino +% 48, 9)
            origen = origen +% fila
            destino = destino +% 64
            k = k +% 1
        }
        jb += 16
    }
    // A: pares de filas intercalados.
    change i = 0
    during i < n {
        change fila0 = a + i * fila
        change fila1 = fila0 + fila
        change destino = ap + i * fila
        change k = 0
        during k < n {
            escribir32(destino, leer32(fila0))
            escribir32(destino +% 4, leer32(fila1))
            fila0 = fila0 +% 4
            fila1 = fila1 +% 4
            destino = destino +% 8
            k = k +% 1
        }
        i += 2
    }
}

// Micronúcleo 2 x 16: dos filas de C (i, i+1) por 16 columnas. Ocho
// acumuladores en XMM6..XMM9 (fila i) y XMM12..XMM15 (fila i+1); A[i][k] y
// A[i+1][k] difundidos en XMM10 y XMM11. Cada xmmMulSumar4 hace cuatro
// MOVUPS+MULPS+ADDPS sobre 16 floats del panel de B. El bucle en k está
// desenrollado 4 veces y los punteros avanzan con suma envolvente (+%).
flow multiplicar(ap: Int, bp: Int, c: Int, n: Int) {
    hold fila = n * 4
    change i = 0
    during i < n {
        hold pa_inicio = ap + i * fila
        hold pc_inicio = c + i * fila
        change jb = 0
        during jb < n {
            xmmCero(6)
            xmmCero(7)
            xmmCero(8)
            xmmCero(9)
            xmmCero(12)
            xmmCero(13)
            xmmCero(14)
            xmmCero(15)
            change pa = pa_inicio
            change pb = bp + jb * fila
            change k = 0
            during k < n {
                xmmDifundirEn(10, pa, 0)
                xmmDifundirEn(11, pa, 4)
                xmmMulSumar4(6, 10, pb, 0)
                xmmMulSumar4(12, 11, pb, 0)
                xmmDifundirEn(10, pa, 8)
                xmmDifundirEn(11, pa, 12)
                xmmMulSumar4(6, 10, pb, 64)
                xmmMulSumar4(12, 11, pb, 64)
                xmmDifundirEn(10, pa, 16)
                xmmDifundirEn(11, pa, 20)
                xmmMulSumar4(6, 10, pb, 128)
                xmmMulSumar4(12, 11, pb, 128)
                xmmDifundirEn(10, pa, 24)
                xmmDifundirEn(11, pa, 28)
                xmmMulSumar4(6, 10, pb, 192)
                xmmMulSumar4(12, 11, pb, 192)
                pa = pa +% 32
                pb = pb +% 256
                k = k +% 4
            }
            hold pc = pc_inicio + jb * 4
            xmmGuardar(pc, 6)
            xmmGuardar(pc + 16, 7)
            xmmGuardar(pc + 32, 8)
            xmmGuardar(pc + 48, 9)
            xmmGuardar(pc + fila, 12)
            xmmGuardar(pc + fila + 16, 13)
            xmmGuardar(pc + fila + 32, 14)
            xmmGuardar(pc + fila + 48, 15)
            jb += 16
        }
        i += 2
    }
}

// Ejecuta el banco de pruebas con matrices n x n (n múltiplo de 16).
// Devuelve true si el resultado es exacto.
expose flow sgemmBanco(n: Int) => Bool {
    hold bytes = n * n * 4
    hold a = montonReservar(bytes)
    hold b = montonReservar(bytes)
    hold c = montonReservar(bytes)
    hold ap = montonReservar(bytes)
    hold bp = montonReservar(bytes)
    when a == 0 || b == 0 || c == 0 || ap == 0 || bp == 0 { give false }
    each i among 0..n {
        each j among 0..n {
            escribir32(a + (i * n + j) * 4, f32DeEntero(valorA(i, j)))
            escribir32(b + (i * n + j) * 4, f32DeEntero(valorB(i, j)))
            escribir32(c + (i * n + j) * 4, 0)
        }
    }

    hold t0 = rdtsc()
    empaquetar(a, b, ap, bp, n)
    hold t1 = rdtsc()
    multiplicar(ap, bp, c, n)
    hold t2 = rdtsc()
    hold ciclos = t2 - t0
    hold ciclos_nucleo = t2 - t1

    // Comprobación exacta de una fila de cada 7 (y la última).
    change correcto = true
    change i = 0
    during i < n {
        each j among 0..n {
            change esperado = 0
            each k among 0..n { esperado += valorA(i, k) * valorB(k, j) }
            when enteroDeF32(leer32(c + (i * n + j) * 4)) != esperado { correcto = false }
        }
        when i == n - 1 { i = n } otherwise when i + 7 >= n { i = n - 1 } otherwise { i += 7 }
    }

    hold flops = 2 * n * n * n
    hold ns = ciclos * 1000000 / tscCiclosPorMs()
    kprint(cadena("SGEMM "))
    kprintEntero(n)
    kprint(cadena("x"))
    kprintEntero(n)
    kprint(cadena(": "))
    kprintEntero(ns / 1000)
    kprint(cadena(" us, "))
    kprintEntero(flops * 1000 / ns)
    kprint(cadena(" MFLOPS, "))
    // FLOP por ciclo de TSC (x100). El pico SSE de un núcleo Skylake/Kaby
    // Lake es 8 (un MULPS y un ADDPS de 4 floats por ciclo).
    hold por_ciclo = flops * 100 / ciclos
    kprintEntero(por_ciclo / 100)
    kprintByte(44)
    kprintByte(48 + (por_ciclo / 10) % 10)
    kprintByte(48 + por_ciclo % 10)
    kprint(cadena(" FLOP/ciclo = "))
    kprintEntero(por_ciclo * 100 / 800)
    kprintln(cadena(" % del pico SSE (8 FLOP/ciclo), empaquetado incluido"))
    hold nucleo = flops * 100 / ciclos_nucleo
    kprint(cadena("  solo el micronúcleo: "))
    kprintEntero(nucleo / 100)
    kprintByte(44)
    kprintByte(48 + (nucleo / 10) % 10)
    kprintByte(48 + nucleo % 10)
    kprint(cadena(" FLOP/ciclo = "))
    kprintEntero(nucleo * 100 / 800)
    kprintln(cadena(" % del pico"))
    montonLiberar(bp)
    montonLiberar(ap)
    montonLiberar(c)
    montonLiberar(b)
    montonLiberar(a)
    give correcto
}
