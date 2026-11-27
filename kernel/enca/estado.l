// ENCA: estado completo del modelo rápido en un búfer contiguo, para los
// checkpoints A/B (almacenamiento/checkpoint.l, juego CKPT_ENCA).
//
// Sin punteros: solo escalares y arreglos copiados palabra a palabra (los
// bits exactos de cada Float/Int). Al cargar, el modelo ya está creado con
// modeloCrear (que recalcula lo derivado: tabla R del impulso, 1 - fuga,
// tabla uniforme, decaimiento) y aquí se le copian los datos.
//
// Formato (palabras de 8 bytes, little-endian):
//   0..31  cabecera de ENCA (256 bytes)
//     0 magia "ENCAEST1"   1 versión   2 ranuras del hipocampo   3 órdenes
//     4 ancho   5 capacidad de la ventana   6 n (corteza)   7 k   8 semilla
//     9 modo (1 = rápido)   10 contextos del mezclador   11 expertos
//     12 bytes totales del estado   13 bytes de corpus entrenados
//     14..21 métricas de la prueba A, 22..29 de la prueba B, cada una:
//            bits/byte de mezcla, hipocampo y corteza (los 64 bits del
//            Float), top-1 por mil, caracteres aceptados, restantes,
//            líneas exactas, líneas
//     30..31 reservadas (0)
//   modelo        contextoMezcla, umbralSorpresa, tasaCorteza,
//                 compuertasCerradas, consolidaciones          (5)
//   ventana       cabeza, llenos, bytes[capacidad]             (2 + cap)
//   hipocampo     totalUnigrama, ordenUsado, sobrescrituras, desalojos (4)
//                 unigrama[256] f64
//                 etiquetas, totales, distintos   (órdenes x ranuras cada una)
//                 simbolos, cuentas               (órdenes x ranuras x ancho)
//   corteza       numActivos, actualizaciones                  (2)
//                 vMem[n], umbral[n], activos[k], puntaje[k]   (f64 / Int)
//                 wF[n x 256] f32 (n x 128 palabras), sesgoF[256] f32 (128)
//   mezclador     contexto, pesos[contextos x expertos]
// No se guardan: tablas derivadas, búferes de trabajo (logits, distribución,
// respaldo, listas del núcleo 1), métricas de evaluación del modelo y
// ciclos medidos. Cada documento (iniciarDocumento) reconstruye los activos
// y el potencial desde cero, así que lo guardado de ellos es solo por
// completitud.

take nucleo.cpu
take nucleo.mem

fixed MAGIA_ENCA = 0x3154534541434E45        // "ENCAEST1"
fixed VERSION_ENCA = 1
fixed CAB_PALABRAS = 32

// Configuración de ENCA C5 (la que crea modeloCrear).
expose fixed ENCA_RANURAS = 65536
expose fixed ENCA_ORDENES = 5
expose fixed ENCA_ANCHO = 12
expose fixed ENCA_VENTANA = 8
expose fixed ENCA_N = 512
expose fixed ENCA_K = 16
expose fixed ENCA_SEMILLA = 2026
expose fixed ENCA_CONTEXTOS = 6
expose fixed ENCA_EXPERTOS = 2

// Primera palabra de las métricas dentro de la cabecera.
expose fixed ENCA_CAB_METRICAS = 14
expose fixed ENCA_CAB_BYTES = 12
expose fixed ENCA_CAB_ENTRENADOS = 13

// Tamaño en bytes del estado de la configuración C5.
expose flow encaTamEstado() => Int {
    hold ts = ENCA_ORDENES * ENCA_RANURAS
    hold te = ts * ENCA_ANCHO
    hold modelo = 5
    hold ventana = 2 + ENCA_VENTANA
    hold hipocampo = 4 + 256 + 3 * ts + 2 * te
    hold corteza = 2 + 2 * ENCA_N + 2 * ENCA_K + ENCA_N * 128 + 128
    hold mezclador = 1 + ENCA_CONTEXTOS * ENCA_EXPERTOS
    give (CAB_PALABRAS + modelo + ventana + hipocampo + corteza + mezclador) * 8
}

// Cursor de la transferencia (bytes desde el inicio del búfer).
flow cursor() => Int { give reservar(8, 8) }

// Copia `palabras` entre el modelo (`dir`) y el búfer en la posición del
// cursor y lo avanza. guardar: modelo -> búfer; si no, búfer -> modelo.
flow mover(guardar: Bool, buf: Int, dir: Int, palabras: Int) {
    hold c = cursor()
    hold pos = buf + leer64(c)
    hold bytes = palabras * 8
    change p = 0
    when guardar {
        during p < bytes {
            escribir64(pos +% p, leer64(dir +% p))
            p = p +% 8
        }
    } otherwise {
        during p < bytes {
            escribir64(dir +% p, leer64(pos +% p))
            p = p +% 8
        }
    }
    escribir64(c, leer64(c) + bytes)
}

// Recorre todo el estado en el orden del formato. Devuelve los bytes
// recorridos (incluida la cabecera).
flow transferir(guardar: Bool, m: Int, buf: Int) => Int {
    hold v = leer64(m)
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold mez = leer64(m + 24)
    escribir64(cursor(), CAB_PALABRAS * 8)
    // modelo
    mover(guardar, buf, m + 40, 5)
    // ventana
    mover(guardar, buf, v + 8, 2)
    mover(guardar, buf, v + 40, leer64(v))
    // hipocampo
    hold ts = leer64(mem) * leer64(mem + 8)
    hold te = ts * leer64(mem + 16)
    mover(guardar, buf, mem + 64, 4)
    mover(guardar, buf, mem + 96, 256)
    mover(guardar, buf, leer64(mem + 24), ts)
    mover(guardar, buf, leer64(mem + 48), ts)
    mover(guardar, buf, leer64(mem + 56), ts)
    mover(guardar, buf, leer64(mem + 32), te)
    mover(guardar, buf, leer64(mem + 40), te)
    // corteza
    hold n = leer64(cor)
    hold k = leer64(cor + 8)
    mover(guardar, buf, cor + 80, 1)
    mover(guardar, buf, cor + 184, 1)
    mover(guardar, buf, leer64(cor + 40), n)
    mover(guardar, buf, leer64(cor + 56), n)
    mover(guardar, buf, leer64(cor + 64), k)
    mover(guardar, buf, leer64(cor + 72), k)
    mover(guardar, buf, leer64(cor + 192), n * 128)
    mover(guardar, buf, leer64(cor + 200), 128)
    // mezclador
    mover(guardar, buf, mez + 24, 1)
    mover(guardar, buf, leer64(mez + 32), leer64(mez) * leer64(mez + 8))
    give leer64(cursor())
}

// Serializa el modelo en `buf` (de al menos encaTamEstado() + 512 bytes).
// Deja las métricas de la cabecera en cero: las rellena quien llama.
// Devuelve los bytes del estado (0 si la configuración no es la C5).
expose flow encaSerializar(m: Int, buf: Int, entrenados: Int) => Int {
    hold v = leer64(m)
    hold mem = leer64(m + 8)
    hold cor = leer64(m + 16)
    hold mez = leer64(m + 24)
    each i among 0..CAB_PALABRAS { escribir64(buf + i * 8, 0) }
    escribir64(buf, MAGIA_ENCA)
    escribir64(buf + 8, VERSION_ENCA)
    escribir64(buf + 16, leer64(mem + 8))
    escribir64(buf + 24, leer64(mem))
    escribir64(buf + 32, leer64(mem + 16))
    escribir64(buf + 40, leer64(v))
    escribir64(buf + 48, leer64(cor))
    escribir64(buf + 56, leer64(cor + 8))
    escribir64(buf + 64, leer64(cor + 16))
    escribir64(buf + 72, leer64(m + 216))
    escribir64(buf + 80, leer64(mez))
    escribir64(buf + 88, leer64(mez + 8))
    escribir64(buf + 104, entrenados)
    hold total = transferir(true, m, buf)
    when total != encaTamEstado() { give 0 }
    escribir64(buf + 96, total)
    // El último sector se escribe completo: el relleno va a cero.
    change z = total
    during z < (total + 511) / 512 * 512 {
        escribir64(buf + z, 0)
        z += 8
    }
    give total
}

// ¿La cabecera describe la configuración C5 en modo rápido y este formato?
expose flow encaCabeceraCompatible(buf: Int) => Bool {
    when leer64(buf) != MAGIA_ENCA || leer64(buf + 8) != VERSION_ENCA { give false }
    when leer64(buf + 16) != ENCA_RANURAS || leer64(buf + 24) != ENCA_ORDENES { give false }
    when leer64(buf + 32) != ENCA_ANCHO || leer64(buf + 40) != ENCA_VENTANA { give false }
    when leer64(buf + 48) != ENCA_N || leer64(buf + 56) != ENCA_K { give false }
    when leer64(buf + 64) != ENCA_SEMILLA || leer64(buf + 72) != 1 { give false }
    when leer64(buf + 80) != ENCA_CONTEXTOS || leer64(buf + 88) != ENCA_EXPERTOS { give false }
    give leer64(buf + 96) == encaTamEstado()
}

// Copia el estado de `buf` en el modelo `m` (recién creado con la misma
// configuración, en modo rápido) y recalcula el espejo f32 del unigrama.
expose flow encaDeserializar(m: Int, buf: Int) => Bool {
    when !encaCabeceraCompatible(buf) { give false }
    hold total = transferir(false, m, buf)
    when total != leer64(buf + 96) { give false }
    hold mem = leer64(m + 8)
    hold unigramaF = leer64(mem + 4192)
    each c among 0..256 { escribirF32(unigramaF + c * 4, floatDeBits(leer64(mem + 96 + c * 8))) }
    give true
}
