// ENCA: elección del siguiente byte por muestreo (hito 18).
//
// El modo rápido da la distribución de la mezcla (256 probabilidades en f32).
// Con argmax (voraz) el modelo cae en bucles ("hold a = 1; hold a = 1; ...").
// Aquí el byte se elige así, todo en orden fijo y sin depender del tiempo:
//
//  1. Penalización por continuación de n-grama. Para cada posición j de la
//     ventana de los últimos W bytes (prefijo + generado) donde el sufijo
//     actual, de longitud L >= m, ya apareció terminando en j, el byte que
//     siguió (hist[j+1]) se penaliza. A nivel de byte una penalización por
//     "presencia" castigaría siempre a los espacios y a las letras comunes;
//     esta solo castiga repetir una secuencia ya vista.
//     Exponente e del byte candidato (el mayor entre sus emparejamientos):
//       modo 0: e = 1                     (una vez por byte candidato)
//       modo 1: e = min(1 + (L-m)/4, EMAX)  (crece con la longitud del emparejamiento)
//     p_c <- p_c / pen^e.
//  2. Temperatura: p_c ∝ p_c^(1/T). T = 0 equivale a argmax (sobre las
//     probabilidades ya penalizadas).
//  3. top-k (k = 0: desactivado) y top-p (p = 1: desactivado) sobre la
//     distribución con temperatura, con los candidatos ordenados de mayor a
//     menor (a igual puntuación, primero el byte menor).
//  4. Inversión de la CDF con un PCG32 sembrado (misma semilla y mismo
//     prompt => mismos bytes). Cada completado re-siembra con la semilla
//     configurada: la semilla NO avanza entre completados.
//
// Los cálculos van en logaritmos: s_c = (ln p_c - e_c ln pen) / T, y se
// descartan los bytes con s_c < s_max - 16 (peso relativo < 1e-7).

take nucleo.cpu
take nucleo.mem
take lib.consola
take lib.aleatorio
take lib.matf64
take enca.matematica
take enca.modelo

fixed HIST_CAP = 3072
fixed MAX_EMPAREJAR = 64
fixed MAX_EXPONENTE = 8.0

// Configuración (bloque de 128 bytes):
//  +0 voraz (0/1)  +8 temperatura (F)  +16 top-k  +24 top-p (F)  +32 pen (F)
//  +40 ventana  +48 semilla  +56 parar en '\n' (0/1)  +64 m (n-grama mínimo)
//  +72 modo del exponente (0/1)
flow config() => Int { give reservar(128, 8) }

// Estado del generador (64 bytes): +0 largo de la historia, +8 PCG (16 bytes).
flow gen() => Int { give reservar(64, 8) }
flow historia() => Int { give reservar(HIST_CAP, 8) }
flow exponentes() => Int { give reservar(2048, 8) }
flow puntos() => Int { give reservar(2048, 8) }
flow candIdx() => Int { give reservar(2048, 8) }
flow candPun() => Int { give reservar(2048, 8) }

// Valores por defecto (justificados en kernel/docs/bitacora.md, hito 18).
expose flow mzDefecto() {
    hold c = config()
    escribir64(c, 0)
    ef(c + 8, 0.5)
    escribir64(c + 16, 10)
    ef(c + 24, 1.0)
    ef(c + 32, 2.0)
    escribir64(c + 40, 128)
    escribir64(c + 48, 1)
    escribir64(c + 56, 1)
    escribir64(c + 64, 4)
    escribir64(c + 72, 1)
}

expose flow mzFijarSemilla(s: Int) { escribir64(config() + 48, s) }
expose flow mzFijarVoraz(v: Int) { escribir64(config(), v) }
expose flow mzFijarLinea(v: Int) { escribir64(config() + 56, v) }
expose flow mzFijarTemp(t: Float) { ef(config() + 8, t) }
expose flow mzFijarTopK(k: Int) { escribir64(config() + 16, k) }
expose flow mzFijarTopP(p: Float) { ef(config() + 24, p) }
expose flow mzFijarPen(p: Float) { ef(config() + 32, p) }
expose flow mzFijarVentana(w: Int) { escribir64(config() + 40, w) }
expose flow mzFijarModoExp(x: Int) { escribir64(config() + 72, x) }
expose flow mzFijarMinimo(x: Int) { escribir64(config() + 64, x) }
expose flow mzParaEnLinea() => Bool { give leer64(config() + 56) == 1 }
expose flow mzEsVoraz() => Bool { give leer64(config()) == 1 }

// Prepara un completado: documento nuevo, prefijo condicionado, historia con
// el prefijo (los últimos HIST_CAP-256 bytes) y PCG re-sembrado.
expose flow mzIniciar(m: Int, prefijo: Int, n: Int) {
    modeloIniciarDocumento(m)
    each i among 0..n { condicionar(m, leer8(prefijo + i)) }
    hold h = historia()
    change inicio = 0
    when n > HIST_CAP - 256 { inicio = n - (HIST_CAP - 256) }
    each i among inicio..n { escribir8(h + (i - inicio), leer8(prefijo + i)) }
    hold g = gen()
    escribir64(g, n - inicio)
    pcgSembrar(g + 8, leer64(config() + 48), 54)
}

// Rellena exponentes[c] con la penalización de continuación de n-grama.
flow penalizaciones() {
    hold cfg = config()
    hold g = gen()
    hold hist = historia()
    hold ex = exponentes()
    each c among 0..256 { ef(ex + c * 8, 0.0) }
    hold h = leer64(g)
    hold mm = leer64(cfg + 64)
    hold modo = leer64(cfg + 72)
    change ini = h - leer64(cfg + 40)
    when ini < 0 { ini = 0 }
    when h < 2 { give }
    hold ultimo = leer8(hist + h - 1)
    each j among ini..(h - 1) {
        when leer8(hist + j) == ultimo {
            change largo = 1
            change sigue = true
            during sigue {
                when largo >= MAX_EMPAREJAR || j - largo < ini {
                    sigue = false
                } otherwise when leer8(hist + j - largo) == leer8(hist + h - 1 - largo) {
                    largo += 1
                } otherwise {
                    sigue = false
                }
            }
            when largo >= mm {
                hold c = leer8(hist + j + 1)
                change e = 1.0
                when modo == 1 {
                    e = 1.0 + Float(largo - mm) * 0.25
                    when e > MAX_EXPONENTE { e = MAX_EXPONENTE }
                }
                when e > lf(ex + c * 8) { ef(ex + c * 8, e) }
            }
        }
    }
}

// Elige el siguiente byte de la distribución de la mezcla (modelo rápido ya
// predicho). Muestreo: ver la cabecera.
flow elegir(m: Int) => Int {
    hold cfg = config()
    hold g = gen()
    hold dist = leer64(leer64(m + 24) + 80)
    hold pun = puntos()
    hold ex = exponentes()
    hold pen = lf(cfg + 32)
    hold temp = lf(cfg + 8)
    penalizaciones()
    hold lnPen = lnRapido(pen)
    change maximo = -1.0e30
    change mejor = 0
    each c among 0..256 {
        hold p = leerF32(dist + c * 4)
        change s = -1.0e30
        when p > 0.000000001 {
            s = lnRapido(p) - lf(ex + c * 8) * lnPen
            when temp > 0.000001 { s = s / temp }
        }
        ef(pun + c * 8, s)
        when s > maximo {
            maximo = s
            mejor = c
        }
    }
    when temp <= 0.000001 { give mejor }
    // Candidatos (peso relativo >= e^-16), ordenados de mayor a menor.
    hold ci = candIdx()
    hold cp = candPun()
    change nc = 0
    change cap = leer64(cfg + 16)
    when cap == 0 || cap > 256 { cap = 256 }
    each c among 0..256 {
        hold s = lf(pun + c * 8)
        // Lista acotada a `cap` (= top-k): equivale a ordenar todos y cortar.
        when s >= maximo - 16.0 && (nc < cap || s > lf(cp + (cap - 1) * 8)) {
            change r = nc
            when nc == cap { r = cap - 1 }
            during r > 0 && lf(cp + (r - 1) * 8) < s {
                escribir64(ci + r * 8, leer64(ci + (r - 1) * 8))
                ef(cp + r * 8, lf(cp + (r - 1) * 8))
                r -= 1
            }
            escribir64(ci + r * 8, c)
            ef(cp + r * 8, s)
            when nc < cap { nc += 1 }
        }
    }
    change k = nc
    // Pesos de los k primeros y masa total.
    change total = 0.0
    each i among 0..k {
        hold w = expFloat(lf(cp + i * 8) - maximo)
        ef(cp + i * 8, w)
        total += w
    }
    // top-p: el núcleo mínimo con masa >= p (inclusive el que cruza).
    hold topp = lf(cfg + 24)
    when topp < 0.9999999 {
        change acum = 0.0
        change corte = k
        change i = 0
        during i < k {
            acum += lf(cp + i * 8) / total
            when acum >= topp {
                corte = i + 1
                i = k
            } otherwise {
                i += 1
            }
        }
        k = corte
        total = 0.0
        each j among 0..k { total += lf(cp + j * 8) }
    }
    hold u = pcgUniforme(g + 8) * total
    change acum = 0.0
    each i among 0..k {
        acum += lf(cp + i * 8)
        when u < acum { give leer64(ci + i * 8) }
    }
    give leer64(ci + (k - 1) * 8)
}

// Siguiente byte (voraz o muestreado); lo condiciona en el modelo y lo añade
// a la historia.
expose flow mzSiguiente(m: Int, voraz: Bool) => Int {
    hold mejor = modeloPredecirMezcla(m)
    change b = mejor
    when !voraz { b = elegir(m) }
    condicionar(m, b)
    hold g = gen()
    hold h = leer64(g)
    when h < HIST_CAP {
        escribir8(historia() + h, b)
        escribir64(g, h + 1)
    } otherwise {
        // Historia llena: se desplaza un byte.
        hold hs = historia()
        each i among 1..HIST_CAP { escribir8(hs + i - 1, leer8(hs + i)) }
        escribir8(hs + HIST_CAP - 1, b)
    }
    give b
}

// ¿Hay una subcadena de largo L (8..66) repetida 4 veces seguidas?
expose flow mzTieneBucle(buf: Int, n: Int) => Bool {
    each largo among 8..67 {
        change lim = n - 4 * largo + 1
        when lim < 0 { lim = 0 }
        each ini among 0..lim {
            change iguales = true
            change i = 0
            during iguales && i < 3 * largo {
                when leer8(buf + ini + i) != leer8(buf + ini + i + largo) { iguales = false }
                i += 1
            }
            when iguales { give true }
        }
    }
    give false
}

// ---- comandos de ENCA> ----------------------------------------------------------

flow minuscula(cp: Int) => Int {
    when cp >= 65 && cp <= 90 { give cp + 32 }
    give cp
}

// ¿La palabra (n puntos de código en `pal`) es la cadena `c`?
flow esPalabra(pal: Int, n: Int, c: Int) => Bool {
    when leer64(c) != n { give false }
    each i among 0..n {
        when minuscula(leer64(pal + i * 8)) != leer8(c + 8 + i) { give false }
    }
    give true
}

// Entero decimal sin signo de linea[a..b). `ok` (dirección) recibe 1 o 0.
flow leerEntero(linea: Int, a: Int, b: Int, ok: Int) => Int {
    escribir64(ok, 0)
    when a >= b || b - a > 15 { give 0 }
    change v = 0
    each i among a..b {
        hold cp = leer64(linea + i * 8)
        when cp < 48 || cp > 57 { give 0 }
        v = v * 10 + (cp - 48)
    }
    escribir64(ok, 1)
    give v
}

// Decimal con punto o coma de linea[a..b).
flow leerDecimal(linea: Int, a: Int, b: Int, ok: Int) => Float {
    escribir64(ok, 0)
    when a >= b || b - a > 15 { give 0.0 }
    change entera = 0
    change frac = 0
    change escala = 1
    change vistoPunto = false
    change digitos = 0
    each i among a..b {
        hold cp = leer64(linea + i * 8)
        when cp == 46 || cp == 44 {
            when vistoPunto { give 0.0 }
            vistoPunto = true
        } otherwise when cp >= 48 && cp <= 57 {
            digitos += 1
            when vistoPunto {
                frac = frac * 10 + (cp - 48)
                escala = escala * 10
            } otherwise {
                entera = entera * 10 + (cp - 48)
            }
        } otherwise {
            give 0.0
        }
    }
    when digitos == 0 { give 0.0 }
    escribir64(ok, 1)
    give Float(entera) + Float(frac) / Float(escala)
}

flow imprimirConfig() {
    hold c = config()
    when leer64(c) == 1 {
        kprintln(cadena("  modo: voraz (argmax de la mezcla)"))
    } otherwise {
        kprintln(cadena("  modo: muestreo"))
    }
    kprint(cadena("  temp "))
    kprintDecimal(lf(c + 8), 3)
    kprint(cadena("  topk "))
    kprintEntero(leer64(c + 16))
    kprint(cadena("  topp "))
    kprintDecimal(lf(c + 24), 3)
    kprint(cadena("  pen "))
    kprintDecimal(lf(c + 32), 3)
    kprint(cadena("  ventana "))
    kprintEntero(leer64(c + 40))
    kprint(cadena("  semilla "))
    kprintEntero(leer64(c + 48))
    kprint(cadena("  linea "))
    when leer64(c + 56) == 1 { kprintln(cadena("si")) } otherwise { kprintln(cadena("no")) }
}

flow ayuda() {
    kprintln(cadena("  :temp x    temperatura (0 = argmax tras penalizar; defecto 0,5)"))
    kprintln(cadena("  :topk n    quedarse con los n mas probables (0 = desactivado)"))
    kprintln(cadena("  :topp x    nucleo de masa x, 0 < x <= 1 (1 = desactivado)"))
    kprintln(cadena("  :pen x     penalizacion de repeticion (n-grama), x >= 1 (1 = sin)"))
    kprintln(cadena("  :ventana n bytes recientes que se miran (1..1024)"))
    kprintln(cadena("  :semilla n semilla del PCG32 (cada completado la reusa)"))
    kprintln(cadena("  :linea si|no  parar en salto de linea"))
    kprintln(cadena("  :voraz     argmax puro (sin penalizacion ni azar)"))
    kprintln(cadena("  :muestreo  volver a muestrear"))
    kprintln(cadena("  :ver       mostrar la configuracion   :ayuda  esto"))
}

flow rechazar(texto: Int) {
    kprint(cadena("  error: "))
    kprintln(texto)
    kprintln(cadena("  (no cambia nada; :ayuda muestra los comandos)"))
}

// Ejecuta la línea `linea` (n puntos de código, el primero es ':').
expose flow mzComando(linea: Int, n: Int) {
    // Palabra: de 1 hasta el primer espacio.
    change fin = 1
    during fin < n && leer64(linea + fin * 8) != 32 { fin += 1 }
    hold pal = linea + 8
    hold np = fin - 1
    // Argumento: tras los espacios; sin espacios finales.
    change a = fin
    during a < n && leer64(linea + a * 8) == 32 { a += 1 }
    change b = n
    during b > a && leer64(linea + (b - 1) * 8) == 32 { b -= 1 }
    hold ok = reservar(8, 8)
    hold c = config()
    when np == 0 {
        rechazar(cadena("comando vacío"))
    } otherwise when esPalabra(pal, np, cadena("ver")) {
        imprimirConfig()
    } otherwise when esPalabra(pal, np, cadena("ayuda")) {
        ayuda()
    } otherwise when esPalabra(pal, np, cadena("voraz")) {
        escribir64(c, 1)
        kprintln(cadena("  modo voraz"))
    } otherwise when esPalabra(pal, np, cadena("muestreo")) {
        escribir64(c, 0)
        kprintln(cadena("  modo muestreo"))
    } otherwise when esPalabra(pal, np, cadena("temp")) {
        hold v = leerDecimal(linea, a, b, ok)
        when leer64(ok) == 0 || v > 10.0 {
            rechazar(cadena(":temp espera un decimal entre 0 y 10"))
        } otherwise {
            ef(c + 8, v)
            kprint(cadena("  temp = "))
            kprintDecimal(v, 3)
            kprintByte(10)
        }
    } otherwise when esPalabra(pal, np, cadena("topk")) {
        hold v = leerEntero(linea, a, b, ok)
        when leer64(ok) == 0 || v > 256 {
            rechazar(cadena(":topk espera un entero entre 0 y 256"))
        } otherwise {
            escribir64(c + 16, v)
            kprint(cadena("  topk = "))
            kprintEntero(v)
            kprintByte(10)
        }
    } otherwise when esPalabra(pal, np, cadena("topp")) {
        hold v = leerDecimal(linea, a, b, ok)
        when leer64(ok) == 0 || v <= 0.0 || v > 1.0 {
            rechazar(cadena(":topp espera un decimal en (0, 1]"))
        } otherwise {
            ef(c + 24, v)
            kprint(cadena("  topp = "))
            kprintDecimal(v, 3)
            kprintByte(10)
        }
    } otherwise when esPalabra(pal, np, cadena("pen")) {
        hold v = leerDecimal(linea, a, b, ok)
        when leer64(ok) == 0 || v < 1.0 || v > 100.0 {
            rechazar(cadena(":pen espera un decimal entre 1 y 100"))
        } otherwise {
            ef(c + 32, v)
            kprint(cadena("  pen = "))
            kprintDecimal(v, 3)
            kprintByte(10)
        }
    } otherwise when esPalabra(pal, np, cadena("ventana")) {
        hold v = leerEntero(linea, a, b, ok)
        when leer64(ok) == 0 || v < 1 || v > 1024 {
            rechazar(cadena(":ventana espera un entero entre 1 y 1024"))
        } otherwise {
            escribir64(c + 40, v)
            kprint(cadena("  ventana = "))
            kprintEntero(v)
            kprintByte(10)
        }
    } otherwise when esPalabra(pal, np, cadena("semilla")) {
        hold v = leerEntero(linea, a, b, ok)
        when leer64(ok) == 0 {
            rechazar(cadena(":semilla espera un entero sin signo"))
        } otherwise {
            escribir64(c + 48, v)
            kprint(cadena("  semilla = "))
            kprintEntero(v)
            kprintByte(10)
        }
    } otherwise when esPalabra(pal, np, cadena("linea")) {
        when b - a == 2 && minuscula(leer64(linea + a * 8)) == 115 && minuscula(leer64(linea + (a + 1) * 8)) == 105 {
            escribir64(c + 56, 1)
            kprintln(cadena("  linea = si"))
        } otherwise when b - a == 2 && minuscula(leer64(linea + a * 8)) == 110 && minuscula(leer64(linea + (a + 1) * 8)) == 111 {
            escribir64(c + 56, 0)
            kprintln(cadena("  linea = no"))
        } otherwise {
            rechazar(cadena(":linea espera si o no"))
        }
    } otherwise {
        rechazar(cadena("comando desconocido"))
    }
}
