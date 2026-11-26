// SGEMM f32: C (+)= op(A) · op(B), con op = identidad o transpuesta.
//
//   op(A) es M x K, op(B) es K x N, C es M x N; todas por filas con su
//   dimensión principal (lda, ldb, ldc, en elementos). Sin transponer, A
//   es M x K y B es K x N; transpuesta, A está guardada K x M y B, N x K.
//   Requisito: N múltiplo de 16. M y K cualesquiera (K se rellena con
//   ceros hasta múltiplo de 4 al empaquetar).
//
// Método (como BLAS): B se empaqueta en paneles de 16 columnas (64 bytes
// por fila k, alineados a 64); A, en bloques de R filas intercaladas
// (A[i][k] .. A[i+R-1][k] seguidos). El micronúcleo mantiene R x 16
// acumuladores en registros XMM durante todo el bucle en k. Las
// transpuestas solo cambian el empaquetado.
//
// Bloqueo de caché (GotoBLAS): K se recorre en tramos de KC = 256 (un panel
// de B ocupa 16 KB y vive en L1) y las filas en bloques de MC = 96 (A
// empaquetada, 96 KB, en L2). Para cada panel se recorren todos los
// bloques de filas, así el panel no sale de L1.
//
// Paralelo: por cada tramo de K, el núcleo c empaqueta los paneles p con
// p % n == c, barrera, calcula su tramo de filas de C (múltiplo de 6
// filas) y otra barrera antes de reempaquetar. Cada fila
// de C ocupa líneas de caché enteras (N % 16 == 0, ldc % 16 == 0), así
// que dos núcleos nunca escriben la misma línea. Cada núcleo usa su propio
// búfer de A, alineado a 64 bytes.
//
// Variantes del micronúcleo (SGEMM_VARIANTE):
//   0  2 x 16, MOVUPS + MULPS (xmmMulSumar4)
//   1  2 x 16, MULPS con operando en memoria (xmmMulSumar4M)
//   2  3 x 16, MULPS con operando en memoria: 12 acumuladores (XMM4..15),
//      3 difusiones (XMM1..3) y XMM0 temporal
// Registros XMM1..XMM5 también los usa el código Float: aquí no hay Float.

take nucleo.cpu
take nucleo.mem
take mem.monton
take cpu.buzon

expose fixed SGEMM_2x16_MOVUPS = 0
expose fixed SGEMM_2x16_MEMORIA = 1
expose fixed SGEMM_3x16_MEMORIA = 2

// Descriptor (uno solo, compartido por los núcleos):
fixed D_M = 0
fixed D_N = 8
fixed D_K = 16
fixed D_A = 24
fixed D_LDA = 32
fixed D_TA = 40
fixed D_B = 48
fixed D_LDB = 56
fixed D_TB = 64
fixed D_C = 72
fixed D_LDC = 80
fixed D_ACUM = 88
fixed D_VARIANTE = 96
fixed D_NUCLEOS = 104
fixed D_KP = 112
fixed D_PANELES = 120     // búfer de paneles de B (alineado a 64)
fixed D_GEN = 128         // generación de la barrera
fixed D_BUFA = 136        // búferes de A por núcleo (MAX_NUCLEOS palabras)

fixed KC = 256
fixed MC = 96

flow descriptor() => Int { give reservar(256, 64) }

// Búferes que crecen según el tamaño pedido: +0 paneles (dirección, bytes),
// +16.. A por núcleo (dirección, bytes).
flow bufferes() => Int { give reservar(16 * (MAX_NUCLEOS + 1), 8) }

// Dirección alineada a 64 de un búfer de al menos `bytes` (se reutiliza).
flow bufer(ranura: Int, bytes: Int) => Int {
    hold r = bufferes() + ranura * 16
    when leer64(r + 8) < bytes {
        when leer64(r) != 0 { montonLiberar(leer64(r)) }
        escribir64(r, montonReservar(bytes + 64))
        escribir64(r + 8, bytes)
    }
    // Con máscara: las direcciones del montón (0xFFFFC000...) son Int
    // negativos y la división redondea hacia cero, es decir, hacia arriba.
    give (leer64(r) + 63) & (~63)
}

// ---- empaquetado -----------------------------------------------------------

// Paneles p = primero, primero + paso, ... de op(B).
// Tramo k0 .. k0+kc-1 (kp = kc redondeado a 4; el resto, ceros).
flow empaquetarB(d: Int, primero: Int, paso: Int, k0: Int, kc: Int, kp: Int) {
    hold n = leer64(d + D_N)
    hold b = leer64(d + D_B)
    hold ldb = leer64(d + D_LDB)
    hold transpuesta = leer64(d + D_TB) == 1
    hold paneles = leer64(d + D_PANELES)
    change p = primero
    during p * 16 < n {
        hold jb = p * 16
        change destino = paneles + p * kp * 64
        change k = 0
        during k < kp {
            when k >= kc {
                xmmCero(1)
                xmmGuardar(destino, 1)
                xmmGuardar(destino +% 16, 1)
                xmmGuardar(destino +% 32, 1)
                xmmGuardar(destino +% 48, 1)
            } otherwise when !transpuesta {
                hold origen = b + ((k0 + k) * ldb + jb) * 4
                xmmCargar(1, origen)
                xmmCargar(2, origen +% 16)
                xmmCargar(3, origen +% 32)
                xmmCargar(4, origen +% 48)
                xmmGuardar(destino, 1)
                xmmGuardar(destino +% 16, 2)
                xmmGuardar(destino +% 32, 3)
                xmmGuardar(destino +% 48, 4)
            } otherwise {
                // B guardada N x K: op(B)[k][j] = B[j][k], paso ldb.
                change origen = b + (jb * ldb + k0 + k) * 4
                hold salto = ldb * 4
                each j among 0..16 {
                    escribir32(destino +% j * 4, leer32(origen))
                    origen = origen +% salto
                }
            }
            destino = destino +% 64
            k = k +% 1
        }
        p += paso
    }
}

// Filas i .. i+r-1 de op(A), columnas k0 .. k0+kc-1, intercaladas, en
// `destino` (kp * r floats; de kc a kp, ceros).
flow empaquetarA(d: Int, i: Int, r: Int, destino: Int, k0: Int, kc: Int, kp: Int) {
    hold k_total = kc
    hold a = leer64(d + D_A)
    hold lda = leer64(d + D_LDA)
    hold transpuesta = leer64(d + D_TA) == 1
    each f among 0..r {
        hold fila = i + f
        change escritura = destino + f * 4
        hold salto = r * 4
        change k = 0
        when transpuesta {
            // A guardada K x M: op(A)[fila][k] = A[k][fila], paso lda.
            change origen = a + (k0 * lda + fila) * 4
            hold paso = lda * 4
            during k < k_total {
                escribir32(escritura, leer32(origen))
                origen = origen +% paso
                escritura = escritura +% salto
                k = k +% 1
            }
        } otherwise {
            change origen = a + (fila * lda + k0) * 4
            during k < k_total {
                escribir32(escritura, leer32(origen))
                origen = origen +% 4
                escritura = escritura +% salto
                k = k +% 1
            }
        }
        during k < kp {
            escribir32(escritura, 0)
            escritura = escritura +% salto
            k = k +% 1
        }
    }
}

// ---- micronúcleos ----------------------------------------------------------
// pa: bloque de A empaquetado; pb: panel de B; pc: C[i][jb]; fila: ldc * 4.

flow mk1(pa: Int, pb_inicio: Int, pc: Int, kp: Int, acumular: Bool) {
    when acumular {
        xmmCargar(4, pc)
        xmmCargar(5, pc + 16)
        xmmCargar(6, pc + 32)
        xmmCargar(7, pc + 48)
    } otherwise {
        xmmCero(4)
        xmmCero(5)
        xmmCero(6)
        xmmCero(7)
    }
    change a = pa
    change pb = pb_inicio
    change k = 0
    during k < kp {
        xmmDifundirEn(1, a, 0)
        xmmMulSumar4M(4, 1, pb, 0)
        xmmDifundirEn(1, a, 4)
        xmmMulSumar4M(4, 1, pb, 64)
        xmmDifundirEn(1, a, 8)
        xmmMulSumar4M(4, 1, pb, 128)
        xmmDifundirEn(1, a, 12)
        xmmMulSumar4M(4, 1, pb, 192)
        a = a +% 16
        pb = pb +% 256
        k = k +% 4
    }
    xmmGuardar(pc, 4)
    xmmGuardar(pc + 16, 5)
    xmmGuardar(pc + 32, 6)
    xmmGuardar(pc + 48, 7)
}

flow cargarFila2(pc: Int, fila: Int, acumular: Bool) {
    when acumular {
        xmmCargar(4, pc)
        xmmCargar(5, pc + 16)
        xmmCargar(6, pc + 32)
        xmmCargar(7, pc + 48)
        xmmCargar(8, pc + fila)
        xmmCargar(9, pc + fila + 16)
        xmmCargar(10, pc + fila + 32)
        xmmCargar(11, pc + fila + 48)
    } otherwise {
        xmmCero(4)
        xmmCero(5)
        xmmCero(6)
        xmmCero(7)
        xmmCero(8)
        xmmCero(9)
        xmmCero(10)
        xmmCero(11)
    }
}

flow guardarFila2(pc: Int, fila: Int) {
    xmmGuardar(pc, 4)
    xmmGuardar(pc + 16, 5)
    xmmGuardar(pc + 32, 6)
    xmmGuardar(pc + 48, 7)
    xmmGuardar(pc + fila, 8)
    xmmGuardar(pc + fila + 16, 9)
    xmmGuardar(pc + fila + 32, 10)
    xmmGuardar(pc + fila + 48, 11)
}

// Variante 0: MOVUPS + MULPS.
flow mk2a(pa: Int, pb_inicio: Int, pc: Int, fila: Int, kp: Int, acumular: Bool) {
    cargarFila2(pc, fila, acumular)
    change a = pa
    change pb = pb_inicio
    change k = 0
    during k < kp {
        xmmDifundirEn(1, a, 0)
        xmmDifundirEn(2, a, 4)
        xmmMulSumar4(4, 1, pb, 0)
        xmmMulSumar4(8, 2, pb, 0)
        xmmDifundirEn(1, a, 8)
        xmmDifundirEn(2, a, 12)
        xmmMulSumar4(4, 1, pb, 64)
        xmmMulSumar4(8, 2, pb, 64)
        xmmDifundirEn(1, a, 16)
        xmmDifundirEn(2, a, 20)
        xmmMulSumar4(4, 1, pb, 128)
        xmmMulSumar4(8, 2, pb, 128)
        xmmDifundirEn(1, a, 24)
        xmmDifundirEn(2, a, 28)
        xmmMulSumar4(4, 1, pb, 192)
        xmmMulSumar4(8, 2, pb, 192)
        a = a +% 32
        pb = pb +% 256
        k = k +% 4
    }
    guardarFila2(pc, fila)
}

// Variante 1: MULPS con operando en memoria.
flow mk2b(pa: Int, pb_inicio: Int, pc: Int, fila: Int, kp: Int, acumular: Bool) {
    cargarFila2(pc, fila, acumular)
    change a = pa
    change pb = pb_inicio
    change k = 0
    during k < kp {
        xmmDifundirEn(1, a, 0)
        xmmDifundirEn(2, a, 4)
        xmmMulSumar4M(4, 1, pb, 0)
        xmmMulSumar4M(8, 2, pb, 0)
        xmmDifundirEn(1, a, 8)
        xmmDifundirEn(2, a, 12)
        xmmMulSumar4M(4, 1, pb, 64)
        xmmMulSumar4M(8, 2, pb, 64)
        xmmDifundirEn(1, a, 16)
        xmmDifundirEn(2, a, 20)
        xmmMulSumar4M(4, 1, pb, 128)
        xmmMulSumar4M(8, 2, pb, 128)
        xmmDifundirEn(1, a, 24)
        xmmDifundirEn(2, a, 28)
        xmmMulSumar4M(4, 1, pb, 192)
        xmmMulSumar4M(8, 2, pb, 192)
        a = a +% 32
        pb = pb +% 256
        k = k +% 4
    }
    guardarFila2(pc, fila)
}

// Variante 2: 3 x 16, cada panel de B se usa para las 3 filas.
flow mk3(pa: Int, pb_inicio: Int, pc: Int, fila: Int, kp: Int, acumular: Bool) {
    hold fila2 = fila + fila
    cargarFila2(pc, fila, acumular)
    when acumular {
        xmmCargar(12, pc + fila2)
        xmmCargar(13, pc + fila2 + 16)
        xmmCargar(14, pc + fila2 + 32)
        xmmCargar(15, pc + fila2 + 48)
    } otherwise {
        xmmCero(12)
        xmmCero(13)
        xmmCero(14)
        xmmCero(15)
    }
    change a = pa
    change pb = pb_inicio
    change k = 0
    during k < kp {
        xmmDifundirEn(1, a, 0)
        xmmDifundirEn(2, a, 4)
        xmmDifundirEn(3, a, 8)
        xmmMulSumar4M(4, 1, pb, 0)
        xmmMulSumar4M(8, 2, pb, 0)
        xmmMulSumar4M(12, 3, pb, 0)
        xmmDifundirEn(1, a, 12)
        xmmDifundirEn(2, a, 16)
        xmmDifundirEn(3, a, 20)
        xmmMulSumar4M(4, 1, pb, 64)
        xmmMulSumar4M(8, 2, pb, 64)
        xmmMulSumar4M(12, 3, pb, 64)
        xmmDifundirEn(1, a, 24)
        xmmDifundirEn(2, a, 28)
        xmmDifundirEn(3, a, 32)
        xmmMulSumar4M(4, 1, pb, 128)
        xmmMulSumar4M(8, 2, pb, 128)
        xmmMulSumar4M(12, 3, pb, 128)
        xmmDifundirEn(1, a, 36)
        xmmDifundirEn(2, a, 40)
        xmmDifundirEn(3, a, 44)
        xmmMulSumar4M(4, 1, pb, 192)
        xmmMulSumar4M(8, 2, pb, 192)
        xmmMulSumar4M(12, 3, pb, 192)
        a = a +% 48
        pb = pb +% 256
        k = k +% 4
    }
    guardarFila2(pc, fila)
    xmmGuardar(pc + fila2, 12)
    xmmGuardar(pc + fila2 + 16, 13)
    xmmGuardar(pc + fila2 + 32, 14)
    xmmGuardar(pc + fila2 + 48, 15)
}

// Filas [inicio, fin) de C para el tramo de K ya empaquetado en los
// paneles (kp filas por panel). Bloques de MC filas: se empaquetan en el
// búfer del núcleo y, para cada panel, se recorren todos sus bloques de R
// filas.
flow calcularFilas(d: Int, nucleo: Int, inicio: Int, fin: Int, k0: Int, kc: Int, kp: Int, acumular: Bool) {
    hold n = leer64(d + D_N)
    hold c = leer64(d + D_C)
    hold fila = leer64(d + D_LDC) * 4
    hold variante = leer64(d + D_VARIANTE)
    hold paneles = leer64(d + D_PANELES)
    hold pa_base = leer64(d + D_BUFA + nucleo * 8)
    change r = 2
    when variante == SGEMM_3x16_MEMORIA { r = 3 }
    change ic = inicio
    during ic < fin {
        change mc = MC
        when fin - ic < mc { mc = fin - ic }
        // Empaquetar el bloque: sub-bloques de r filas seguidos.
        change i = 0
        during i < mc {
            change filas = r
            when mc - i < r { filas = mc - i }
            empaquetarA(d, ic + i, filas, pa_base + i * kp * 4, k0, kc, kp)
            i += filas
        }
        change jb = 0
        during jb < n {
            hold pb = paneles + (jb / 16) * kp * 64
            hold pc_col = c + ic * fila + jb * 4
            change j = 0
            during j < mc {
                change filas = r
                when mc - j < r { filas = mc - j }
                hold pa = pa_base + j * kp * 4
                hold pc = pc_col + j * fila
                when filas == 3 {
                    mk3(pa, pb, pc, fila, kp, acumular)
                } otherwise when filas == 2 && variante == SGEMM_2x16_MOVUPS {
                    mk2a(pa, pb, pc, fila, kp, acumular)
                } otherwise when filas == 2 {
                    mk2b(pa, pb, pc, fila, kp, acumular)
                } otherwise {
                    mk1(pa, pb, pc, kp, acumular)
                }
                j += filas
            }
            jb += 16
        }
        ic += mc
    }
}

// Parte del trabajo del núcleo `nucleo` (lo llaman el BSP y los AP).
expose flow sgemmParte(d: Int, nucleo: Int) {
    hold nucleos = leer64(d + D_NUCLEOS)
    hold k_total = leer64(d + D_K)
    hold acumular_inicial = leer64(d + D_ACUM) == 1
    // Tramos de filas múltiplos de 6 (divisibles entre 2 y 3).
    hold m = leer64(d + D_M)
    hold bloques = (m + 5) / 6
    hold inicio = bloques * nucleo / nucleos * 6
    change fin = bloques * (nucleo + 1) / nucleos * 6
    when fin > m { fin = m }
    change generacion = leer64(d + D_GEN)
    change k0 = 0
    during k0 < k_total {
        change kc = KC
        when k_total - k0 < kc { kc = k_total - k0 }
        hold kp = (kc + 3) / 4 * 4
        empaquetarB(d, nucleo, nucleos, k0, kc, kp)
        buzonBarrera(nucleo, nucleos, generacion)
        generacion += 1
        change acumular = true
        when k0 == 0 { acumular = acumular_inicial }
        when inicio < fin { calcularFilas(d, nucleo, inicio, fin, k0, kc, kp, acumular) }
        // Nadie reempaqueta B mientras otro núcleo aún lo lee.
        buzonBarrera(nucleo, nucleos, generacion)
        generacion += 1
        k0 += kc
    }
}

// Código de trabajo para cpu/trabajos.l.
expose fixed TRABAJO_SGEMM = 1

// C (+)= op(A) · op(B) en `nucleos` núcleos (1 = solo el BSP). Devuelve
// false si N no es múltiplo de 16 o no hay memoria.
expose flow sgemm(m: Int, n: Int, k: Int, a: Int, lda: Int, ta: Bool, b: Int, ldb: Int, tb: Bool, c: Int, ldc: Int, acumular: Bool, variante: Int, nucleos: Int) => Bool {
    when n % 16 != 0 || m <= 0 || k <= 0 { give false }
    hold d = descriptor()
    hold kp = (k + 3) / 4 * 4
    escribir64(d + D_M, m)
    escribir64(d + D_N, n)
    escribir64(d + D_K, k)
    escribir64(d + D_A, a)
    escribir64(d + D_LDA, lda)
    escribir64(d + D_TA, 0)
    when ta { escribir64(d + D_TA, 1) }
    escribir64(d + D_B, b)
    escribir64(d + D_LDB, ldb)
    escribir64(d + D_TB, 0)
    when tb { escribir64(d + D_TB, 1) }
    escribir64(d + D_C, c)
    escribir64(d + D_LDC, ldc)
    escribir64(d + D_ACUM, 0)
    when acumular { escribir64(d + D_ACUM, 1) }
    escribir64(d + D_VARIANTE, variante)
    escribir64(d + D_NUCLEOS, nucleos)
    escribir64(d + D_KP, kp)
    change kc_max = KC
    when k < kc_max { kc_max = (k + 3) / 4 * 4 }
    hold paneles = bufer(0, n * kc_max * 4)
    when paneles == 0 { give false }
    escribir64(d + D_PANELES, paneles)
    each c_i among 0..nucleos {
        hold buf = bufer(1 + c_i, (MC + 2) * kc_max * 4)
        when buf == 0 { give false }
        escribir64(d + D_BUFA + c_i * 8, buf)
    }
    // Cada tramo de K usa dos generaciones de barrera.
    escribir64(d + D_GEN, leer64(d + D_GEN) + 2 * ((k + KC - 1) / KC) + 2)
    each c_i among 1..nucleos { buzonPublicar(c_i, TRABAJO_SGEMM, d) }
    sgemmParte(d, 0)
    each c_i among 1..nucleos { buzonEsperarFin(c_i) }
    give true
}
