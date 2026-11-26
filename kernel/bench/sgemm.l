// SGEMM C = A · B (f32, N x N, por filas) con SSE empaquetado: MULPS +
// ADDPS, sin FMA ni AVX (Celeron 3865U).
//
// Micronúcleo: una fila de C por 16 columnas. Los cuatro acumuladores
// (XMM6..XMM9) viven en registros durante todo el bucle en k; en cada paso
// se difunde A[i][k] (XMM10) y se cargan 16 valores de la fila k de B
// (XMM11..XMM14).
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

flow multiplicar(a: Int, b: Int, c: Int, n: Int) {
    each i among 0..n {
        hold fila_a = a + i * n * 4
        hold fila_c = c + i * n * 4
        change jb = 0
        during jb < n {
            xmmCero(6)
            xmmCero(7)
            xmmCero(8)
            xmmCero(9)
            each k among 0..n {
                xmmDifundir(10, fila_a + k * 4)
                hold pb = b + (k * n + jb) * 4
                xmmCargar(11, pb)
                xmmCargar(12, pb + 16)
                xmmCargar(13, pb + 32)
                xmmCargar(14, pb + 48)
                xmmMultiplicar(11, 10)
                xmmMultiplicar(12, 10)
                xmmMultiplicar(13, 10)
                xmmMultiplicar(14, 10)
                xmmSumar(6, 11)
                xmmSumar(7, 12)
                xmmSumar(8, 13)
                xmmSumar(9, 14)
            }
            hold pc = fila_c + jb * 4
            xmmGuardar(pc, 6)
            xmmGuardar(pc + 16, 7)
            xmmGuardar(pc + 32, 8)
            xmmGuardar(pc + 48, 9)
            jb += 16
        }
    }
}

// Ejecuta el banco de pruebas con matrices n x n (n múltiplo de 16).
// Devuelve true si el resultado es exacto.
expose flow sgemmBanco(n: Int) => Bool {
    hold bytes = n * n * 4
    hold a = montonReservar(bytes)
    hold b = montonReservar(bytes)
    hold c = montonReservar(bytes)
    when a == 0 || b == 0 || c == 0 { give false }
    each i among 0..n {
        each j among 0..n {
            escribir32(a + (i * n + j) * 4, f32DeEntero(valorA(i, j)))
            escribir32(b + (i * n + j) * 4, f32DeEntero(valorB(i, j)))
            escribir32(c + (i * n + j) * 4, 0)
        }
    }

    hold t0 = rdtsc()
    multiplicar(a, b, c, n)
    hold ciclos = rdtsc() - t0

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
    kprint(cadena(" MFLOPS ("))
    kprintEntero(flops * 1000 / ns * 1000 / 14400)
    kprintln(cadena(" milésimas del pico SSE de un núcleo 3865U, 14,4 GFLOPS)"))
    montonLiberar(c)
    montonLiberar(b)
    montonLiberar(a)
    give correcto
}
