// ENCA habla español: arranque (enca=hablar), carga del modelo hablante y modo
// conversación de ENCA>.
//
// Arranque (kmain, tras el hito 17 y los demás, antes de ENCA>):
//   enca=hablar   carga y verifica el corpus es/, entrena el hablante, lo evalúa
//                 (por fuente), lo guarda en HABLA_A/B.BIN y muestra 10 ejemplos.
//   (sin opción)  si hay HABLA_A/B.BIN válidas, carga el hablante.
//   enca=charla   (con las ranuras ya guardadas) solo carga y muestra los 10
//                 ejemplos; `charla=T,k,pen,ventana` cambia el muestreo de los ejemplos.
// ENCA> usa el hablante por defecto (con charla); `:modelo codigo` vuelve al de código.
//
// Conversación (:charla si): la línea X del usuario se convierte en el turno de
// teatro "TÚ:\nX\n\n" (como en entrena.bin, donde cada turno es "NOMBRE:\n" y las
// líneas del parlamento, y una línea en blanco entre turnos) y el contexto es el
// historial de turnos anteriores + ese turno + "ENCA:\n". Se genera con el muestreo
// del hito 18 hasta "\n\n" (fin de turno) o 300 bytes. Con :aprender si, el turno
// del usuario (no lo que genera ENCA) se aprende antes como un documento nuevo,
// con el mismo paso de vigilia del hito 21.

take nucleo.cpu
take nucleo.mem
take lib.consola
take lib.matf64
take dispositivos.apic
take dispositivos.teclado
take arranque.limine
take enca.matematica
take enca.modelo
take enca.muestreo
take enca.interactivo
take enca.exp009
take enca.espanol
take enca.aprender
take enca.entrenar

fixed MAX_RESPUESTA = 300
fixed HIST_MAX = 1536
fixed CAP_BUF = 8192

// +0 charla (1/0), +8 bytes del historial, +16 turnos dichos.
flow ch() => Int { give reservar(32, 8) }
flow hist() => Int { give reservar(CAP_BUF, 8) }
flow ctx() => Int { give reservar(CAP_BUF, 8) }
flow trab() => Int { give reservar(CAP_BUF, 8) }
flow resp() => Int { give reservar(512, 8) }

expose flow charlaActiva() => Bool { give leer64(ch()) == 1 }

// ---- utilidades de texto ---------------------------------------------------------

// Copia n bytes de src a dst + pos; devuelve la posición siguiente.
flow copiar(dst: Int, pos: Int, src: Int, n: Int) => Int {
    each i among 0..n { escribir8(dst + pos + i, leer8(src + i)) }
    give pos + n
}

// Añade el contenido de una cadena() (sus bytes UTF-8).
flow poner(dst: Int, pos: Int, texto: Int) => Int {
    give copiar(dst, pos, texto + 8, leer64(texto))
}

// ---- muestreo por defecto para español -----------------------------------------------

// Valores justificados en kernel/docs/bitacora.md ("ENCA aprende español").
flow muestreoEspanol() {
    mzDefecto()
    mzFijarTemp(0.5)
    mzFijarTopK(10)
    mzFijarPen(3.0)
    mzFijarVentana(256)
    mzFijarLinea(0)
}

// ---- una respuesta -------------------------------------------------------------------

// Genera la respuesta de ENCA a los `nu` bytes UTF-8 de `usuario` y la imprime
// ("ENCA: ..."). `conHist`: el contexto incluye el historial y la respuesta se
// añade a él; si no (ejemplos), el contexto es solo este turno. Devuelve 1 si la
// respuesta tiene bucle (mzTieneBucle), si no 0.
flow responder(m: Int, usuario: Int, nu: Int, conHist: Bool, imprimirEstadisticas: Bool) => Int {
    hold c = ctx()
    hold h = hist()
    change nh = 0
    when conHist { nh = leer64(ch() + 8) }
    change n = copiar(c, 0, h, nh)
    n = poner(c, n, cadena("TÚ:\n"))
    n = copiar(c, n, usuario, nu)
    n = poner(c, n, cadena("\n\nENCA:\n"))
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    mzIniciar(m, c, n)
    hold voraz = mzEsVoraz()
    hold r = resp()
    change nr = 0
    change fin = false
    during nr < MAX_RESPUESTA && !fin {
        hold b = mzSiguiente(m, voraz)
        escribir8(r + nr, b)
        nr += 1
        when nr >= 2 && b == 10 && leer8(r + nr - 2) == 10 { fin = true }
    }
    hold t1 = rdtsc()
    change largo = nr
    when fin { largo = nr - 2 }
    kprint(cadena("ENCA: "))
    encaPantallaReiniciar()
    each i among 0..largo { encaMostrarByte(leer8(r + i)) }
    encaPantallaTerminar()
    when largo == 0 { kprint(cadena("(silencio)")) }
    kprintByte(10)
    hold bucle = mzTieneBucle(r, largo)
    when imprimirEstadisticas {
        kprint(cadena("  ["))
        kprintEntero(largo)
        kprint(cadena(" bytes"))
        when !fin { kprint(cadena(", cortada a 300")) }
        kprint(cadena(" en "))
        kprintEntero((t1 - t0) / cpm)
        kprint(cadena(" ms"))
        when bucle { kprint(cadena("; BUCLE")) }
        kprintln(cadena("]"))
    }
    when conHist {
        // Historial: turno del usuario + turno de ENCA, sin pasar de HIST_MAX bytes.
        change p = nh
        p = poner(h, p, cadena("TÚ:\n"))
        p = copiar(h, p, usuario, nu)
        p = poner(h, p, cadena("\n\nENCA:\n"))
        p = copiar(h, p, r, largo)
        p = poner(h, p, cadena("\n\n"))
        during p > HIST_MAX {
            // Quita los dos primeros turnos (hasta el segundo "\n\n").
            change quitar = 0
            change vistos = 0
            change j = 0
            during j + 1 < p && vistos < 2 {
                when leer8(h + j) == 10 && leer8(h + j + 1) == 10 {
                    vistos += 1
                    quitar = j + 2
                    j += 2
                } otherwise {
                    j += 1
                }
            }
            when quitar == 0 || quitar >= p {
                // Un solo turno gigante: se descarta todo.
                p = 0
            } otherwise {
                each i among 0..(p - quitar) { escribir8(h + i, leer8(h + quitar + i)) }
                p = p - quitar
            }
        }
        escribir64(ch() + 8, p)
    }
    escribir64(ch() + 16, leer64(ch() + 16) + 1)
    when bucle { give 1 }
    give 0
}

// Línea del usuario en ENCA> con la charla activa: `nb` bytes UTF-8 en `bytes`
// (con sitio para uno más), `linea` los `n` puntos de código tecleados.
expose flow charlaLinea(m: Int, bytes: Int, nb: Int, linea: Int, n: Int) {
    kprintByte(10)
    when nb == 0 { give }
    when aprendiendo() {
        // El turno del usuario, como documento nuevo: "TÚ:\nX\n" + el '\n' que añade aprLineaBytes.
        hold w = trab()
        change p = poner(w, 0, cadena("TÚ:\n"))
        p = copiar(w, p, bytes, nb)
        escribir8(w + p, 10)
        p += 1
        hold total = aprLineaBytes(m, w, p)
        kprint(cadena("  aprendido: "))
        kprintEntero(total)
        kprint(cadena(" bytes, "))
        kprintDecimal(aprBitsUltima() / Float(total), 3)
        kprint(cadena(" bits/byte  [sin guardar "))
        kprintEntero(aprSinGuardar())
        kprintln(cadena(" bytes]"))
    }
    responder(m, bytes, nb, true, true)
}

// ---- ejemplos fijos ------------------------------------------------------------------

flow prompt(i: Int) => Int {
    when i == 0 { give cadena("Hola, ¿cómo estás?") }
    when i == 1 { give cadena("¿Quién eres?") }
    when i == 2 { give cadena("¿Qué hora es?") }
    when i == 3 { give cadena("Cuéntame una historia.") }
    when i == 4 { give cadena("¿Dónde está el rey?") }
    when i == 5 { give cadena("Te quiero.") }
    when i == 6 { give cadena("¿Qué es la memoria?") }
    when i == 7 { give cadena("Háblame de España.") }
    when i == 8 { give cadena("¿Por qué lloras?") }
    give cadena("Adiós.")
}

// Decimal de los bytes [a, b) del registro de cadena v (dígitos y un punto).
flow decimalDe(v: Int, a: Int, b: Int) => Float {
    change entera = 0
    change frac = 0
    change escala = 1
    change punto = false
    each i among a..b {
        hold c = leer8(v + 8 + i)
        when c == 46 {
            punto = true
        } otherwise when c >= 48 && c <= 57 {
            when punto {
                frac = frac * 10 + (c - 48)
                escala = escala * 10
            } otherwise {
                entera = entera * 10 + (c - 48)
            }
        }
    }
    give Float(entera) + Float(frac) / Float(escala)
}

// Opción charla=T,k,pen,ventana: ajusta el muestreo de los ejemplos (para medir).
flow leerMuestreoDeOpcion() {
    hold v = arranqueOpcion(cadena("charla"))
    when v == 0 { give }
    hold n = leer64(v)
    change campo = 0
    change ini = 0
    each i among 0..n + 1 {
        when i == n || leer8(v + 8 + i) == 44 {
            when i > ini {
                hold x = decimalDe(v, ini, i)
                when campo == 0 { mzFijarTemp(x) }
                when campo == 1 { mzFijarTopK(Int(x)) }
                when campo == 2 { mzFijarPen(x) }
                when campo == 3 { mzFijarVentana(Int(x)) }
            }
            campo += 1
            ini = i + 1
        }
    }
}

// Los 10 ejemplos de conversación (cada uno con un contexto nuevo, sin aprender).
flow ejemplos(m: Int) {
    kprintln(cadena("---- 10 ejemplos de conversación (contexto nuevo en cada uno, sin aprender); muestreo:"))
    // ":ver" como puntos de código, para que mzComando imprima la configuración.
    hold ver = reservar(32, 8)
    escribir64(ver, 58)
    escribir64(ver + 8, 118)
    escribir64(ver + 16, 101)
    escribir64(ver + 24, 114)
    mzComando(ver, 4)
    change bucles = 0
    each i among 0..10 {
        hold p = prompt(i)
        kprint(cadena("["))
        kprintEntero(i + 1)
        kprint(cadena("] TÚ: "))
        kprintln(p)
        bucles += responder(m, p + 8, leer64(p), false, true)
    }
    kprint(cadena("---- ejemplos con bucle: "))
    kprintEntero(bucles)
    kprintln(cadena("/10"))
}

// ---- comandos ----------------------------------------------------------------------------

// Minúscula sin acento (á é í ó ú ñ ü a sus letras base).
flow base(cp: Int) => Int {
    change c = cp
    when c >= 65 && c <= 90 { c = c + 32 }
    when c == 225 { give 97 }
    when c == 233 { give 101 }
    when c == 237 { give 105 }
    when c == 243 { give 111 }
    when c == 250 || c == 252 { give 117 }
    when c == 241 { give 110 }
    give c
}

// ¿linea[a..b) (puntos de código) es la palabra ASCII `c`, sin acentos ni mayúsculas?
flow esPal(linea: Int, a: Int, b: Int, c: Int) => Bool {
    when b - a != leer64(c) { give false }
    each i among 0..b - a {
        when base(leer64(linea + (a + i) * 8)) != leer8(c + 8 + i) { give false }
    }
    give true
}

flow nombrePerfil(p: Int) {
    when p == 1 { kprint(cadena("español (hablante)")) } otherwise { kprint(cadena("código (hito 17)")) }
}

// Activa un perfil (0 código, 1 español) con su muestreo por defecto. La charla
// queda activa solo con el español.
flow cambiarModelo(p: Int) {
    encaFijarPerfil(p)
    when p == 1 {
        muestreoEspanol()
        escribir64(ch(), 1)
    } otherwise {
        mzDefecto()
        escribir64(ch(), 0)
    }
}

flow ayudaCharla() {
    kprintln(cadena("  :modelo codigo|espanol  qué modelo usa ENCA> (por defecto español si está cargado)"))
    kprintln(cadena("  :charla si|no  conversar (turnos TÚ/ENCA con historial) o completar el prefijo"))
    kprintln(cadena("  :nueva     olvidar el historial de la conversación"))
}

// Comandos de este módulo; para :ver y :ayuda añade lo suyo a lo de aprender.l /
// muestreo.l. false si la línea no es de este módulo.
expose flow charlaComando(linea: Int, n: Int) => Bool {
    change fin = 1
    during fin < n && leer64(linea + fin * 8) != 32 { fin += 1 }
    hold np = fin - 1
    change a = fin
    during a < n && leer64(linea + a * 8) == 32 { a += 1 }
    change b = n
    during b > a && leer64(linea + (b - 1) * 8) == 32 { b -= 1 }
    when np == 0 { give false }
    when esPal(linea, 1, fin, cadena("ver")) {
        // Lo de siempre (muestreo y aprendizaje del perfil activo) y, aparte, lo de la charla.
        when !aprComando(linea, n) { mzComando(linea, n) }
        kprint(cadena("  modelo "))
        nombrePerfil(encaPerfil())
        kprint(cadena("  charla "))
        when charlaActiva() { kprint(cadena("si")) } otherwise { kprint(cadena("no")) }
        kprint(cadena("  historial "))
        kprintEntero(leer64(ch() + 8))
        kprint(cadena(" bytes, "))
        kprintEntero(leer64(ch() + 16))
        kprint(cadena(" turnos dichos  ranuras por orden "))
        kprintEntero(encaRanurasEstado())
        kprintByte(10)
        kprint(cadena("  teclado: "))
        kprintEntero(tecladoPorInterrupcion())
        kprint(cadena(" por interrupción, "))
        kprintEntero(tecladoPorSondeo())
        kprint(cadena(" por sondeo, "))
        kprintEntero(tecladoRatonDescartados())
        kprint(cadena(" del touchpad descartados, último estado 8042 "))
        kprintHex(tecladoUltimoEstado())
        kprintByte(10)
        give true
    }
    when esPal(linea, 1, fin, cadena("ayuda")) {
        when !aprComando(linea, n) { mzComando(linea, n) }
        ayudaCharla()
        give true
    }
    when esPal(linea, 1, fin, cadena("modelo")) {
        when esPal(linea, a, b, cadena("espanol")) {
            when encaHablante() == 0 {
                kprintln(cadena("  error: no hay modelo español cargado (arranque con enca=hablar para entrenarlo; no cambia nada)"))
            } otherwise {
                cambiarModelo(1)
                kprint(cadena("  modelo = "))
                nombrePerfil(1)
                kprint(cadena(", charla si, muestreo por defecto del español; "))
                kprintEntero(encaRanurasEstado())
                kprintln(cadena(" ranuras por orden"))
            }
        } otherwise when esPal(linea, a, b, cadena("codigo")) {
            when encaModelo() == 0 {
                kprintln(cadena("  error: no hay modelo de código cargado (no cambia nada)"))
            } otherwise {
                cambiarModelo(0)
                kprintln(cadena("  modelo = código (hito 17), charla no, muestreo por defecto del código"))
            }
        } otherwise {
            kprintln(cadena("  error: :modelo espera codigo o espanol (no cambia nada)"))
        }
        give true
    }
    when esPal(linea, 1, fin, cadena("charla")) {
        when esPal(linea, a, b, cadena("si")) {
            escribir64(ch(), 1)
            kprintln(cadena("  charla = si"))
        } otherwise when esPal(linea, a, b, cadena("no")) {
            escribir64(ch(), 0)
            kprintln(cadena("  charla = no"))
        } otherwise {
            kprintln(cadena("  error: :charla espera si o no (no cambia nada)"))
        }
        give true
    }
    when esPal(linea, 1, fin, cadena("nueva")) {
        escribir64(ch() + 8, 0)
        escribir64(ch() + 16, 0)
        kprintln(cadena("  conversación nueva (historial vacío)"))
        give true
    }
    give false
}

// ---- arranque ------------------------------------------------------------------------------

// Prepara ENCA>: con hablante, perfil español con charla; si no, como siempre.
// El muestreo de ENCA> queda en el del perfil elegido.
expose flow charlaIniciar() {
    escribir64(ch() + 8, 0)
    escribir64(ch() + 16, 0)
    when encaHablante() != 0 {
        cambiarModelo(1)
    } otherwise {
        cambiarModelo(0)
    }
}

// Entrena (enca=hablar) o carga el modelo hablante, y muestra los ejemplos
// (enca=hablar o enca=charla). Va tras el hito 17 y los hitos de disco.
expose flow hablanteArranque() {
    hold pedido = arranqueOpcionEs(cadena("enca"), cadena("hablar"))
    hold demo = arranqueOpcionEs(cadena("enca"), cadena("charla"))
    when pedido {
        kprintln(cadena("ENCA aprende español (enca=hablar): corpus es/, modelo hablante aparte, estado en HABLA_A/B.BIN"))
        hold rc = espCargarCorpus(false, true)
        when rc != 0 {
            kprintln(cadena("enca=hablar: sin corpus español utilizable; sigue el arranque normal"))
        } otherwise {
            when !espEntrenarYGuardar() { kprintln(cadena("enca=hablar: el entrenamiento o el guardado falló")) }
        }
    }
    // Hito 24: enca=entrenar entrena (o reanuda) y deja el modelo como hablante; sin la
    // opción, un entrenamiento TERMINADO en ENTREN_A/B.BIN tiene prioridad sobre HABLA_*.
    hold entrenando = arranqueOpcionEs(cadena("enca"), cadena("entrenar"))
    when entrenando { entrenarArranque() }
    when encaHablante() == 0 {
        hold e = entrenarCargarTerminado()
        when e == 2 { kprintln(cadena("entrenamiento guardado: no se pudo cargar; se prueba con HABLA_A/B.BIN")) }
    }
    when encaHablante() == 0 {
        hold r = espCargarHablante()
        when r == 2 { kprintln(cadena("estado hablante: no se pudo cargar; sigue el arranque normal sin modelo español")) }
    }
    when encaHablante() == 0 { give }
    // Referencias de :guardar/:deshacer del hablante: la evaluación que acaba de hacerse.
    aprInicializarHablante()
    when pedido || demo {
        hold previo = encaPerfil()
        encaFijarPerfil(1)
        muestreoEspanol()
        leerMuestreoDeOpcion()
        ejemplos(encaHablante())
        encaFijarPerfil(previo)
    }
}
