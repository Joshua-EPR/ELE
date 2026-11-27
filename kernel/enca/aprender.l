// ENCA aprende de lo que escribe el usuario (hito 21).
//
// Modelo rápido (el de ENCA>). Con `:aprender si` (por defecto) cada línea
// que se teclea, más su '\n', se procesa como VIGILIA precuencial: documento
// nuevo y, byte a byte, predecir, medir los bits del byte real con la mezcla
// y aprender con el paso de vigilia del entrenamiento (hipocampo, corteza con
// compuerta de sorpresa, mezclador; sin replay). La generación NO aprende.
//
// Protección contra la degradación:
//  * :guardar evalúa las pruebas A y B congeladas (la misma evaluación que usa
//    el hito 17 para las métricas de la cabecera) y compara la mezcla de B con
//    la de la última versión guardada o cargada. Si empeora más que el umbral
//    (bits/byte, `:umbral x`), no guarda. Si pasa, guarda en la OTRA ranura
//    (paso + 1) con las métricas nuevas en la cabecera.
//  * :deshacer con cambios sin guardar recarga la ranura del último estado
//    guardado (descarta lo aprendido). Sin cambios vuelve a la versión
//    anterior (la otra ranura) y la reescribe como paso + 1 en la ranura de la
//    que viene, para que el próximo arranque cargue la versión restaurada.
//
// Estado (80 bytes): +0 no aprender (0 = aprende)  +8 umbral (F)
//   +16 bytes aprendidos sin guardar  +24 ranura del último estado guardado o
//   cargado (-1 ninguna)  +32 su paso  +40 mezcla A de referencia (F)
//   +48 mezcla B de referencia (F)  +56 1 si hay ranuras  +64 bytes de la
//   última pasada  +72 bits de la última pasada (F)  +80 ciclos de la última
//   pasada  +88 delta B del último :guardar (F)  +96 delta A (F)

take nucleo.cpu
take nucleo.mem
take mem.monton
take lib.consola
take lib.matf64
take dispositivos.apic
take almacenamiento.disco
take almacenamiento.fat32
take almacenamiento.checkpoint
take enca.matematica
take enca.estado
take enca.modelo
take enca.muestreo
take enca.exp009

// Umbral por defecto de :guardar (bits/byte de la mezcla en la prueba B).
fixed UMBRAL_DEFECTO = 0.2
fixed VARIANTE_DEFECTO = 3

flow est() => Int { give reservar(128, 8) }
// Línea de trabajo: hasta 4000 bytes más el '\n'.
flow trabajo() => Int { give reservar(4104, 8) }

expose flow aprFijarVariante(v: Int) { escribir64(est() + 104, v) }
expose flow aprVariante() => Int { give leer64(est() + 104) }
expose flow aprFijarUmbral(x: Float) { ef(est() + 8, x) }
expose flow aprendiendo() => Bool { give leer64(est()) == 0 }
expose flow aprSinGuardar() => Int { give leer64(est() + 16) }
expose flow aprUltimoDeltaB() => Float { give lf(est() + 88) }
expose flow aprUmbral() => Float { give lf(est() + 8) }
expose flow aprReferenciaB() => Float { give lf(est() + 48) }
expose flow aprReferenciaA() => Float { give lf(est() + 40) }
expose flow aprPaso() => Int { give leer64(est() + 32) }
expose flow aprRanura() => Int { give leer64(est() + 24) }
expose flow aprBytesUltima() => Int { give leer64(est() + 64) }
expose flow aprBitsUltima() => Float { give lf(est() + 72) }
expose flow aprCiclosUltima() => Int { give leer64(est() + 80) }

// Prepara el estado tras el hito 17: ranura y paso del último estado válido
// de disco y, como referencia, las mezclas A y B de la evaluación que acaba de
// hacer el hito 17 (cargada de disco o recién entrenada). Devuelve true si
// hay modelo y ranuras utilizables.
expose flow aprInicializar() => Bool {
    hold e = est()
    escribir64(e, 0)
    ef(e + 8, UMBRAL_DEFECTO)
    escribir64(e + 104, VARIANTE_DEFECTO)
    escribir64(e + 16, 0)
    escribir64(e + 24, -1)
    escribir64(e + 32, 0)
    escribir64(e + 56, 0)
    when encaModelo() == 0 { give false }
    hold r = encaResultado(1)
    ef(e + 40, lf(r))
    ef(e + 48, lf(r + 32))
    when !discoHayPermitida() { give false }
    when !fatMontar() { give false }
    ckptConfigurar(CKPT_ENCA, encaTamEstadoMax())
    hold pa = ckptPasoRanura(CKPT_ENCA, 0)
    hold pb = ckptPasoRanura(CKPT_ENCA, 1)
    when pa >= 0 || pb >= 0 {
        change ranura = 0
        change paso = pa
        when pb > pa {
            ranura = 1
            paso = pb
        }
        escribir64(e + 24, ranura)
        escribir64(e + 32, paso)
    }
    escribir64(e + 56, 1)
    give true
}

// ---- aprender --------------------------------------------------------------

// Una línea (n bytes en `buf`, con sitio para uno más): se le añade '\n' y se
// procesa como vigilia precuencial. No imprime. Devuelve los bytes procesados;
// deja en +64/+72/+80 bytes, bits totales (F) y ciclos de esta línea.
expose flow aprLineaBytes(m: Int, buf: Int, n: Int) => Int {
    hold e = est()
    escribir8(buf + n, 10)
    hold len = n + 1
    metricasReiniciar(m)
    modeloFijarVariante(leer64(e + 104))
    hold t0 = rdtsc()
    modeloPrecuencial(m, buf, len)
    hold t1 = rdtsc()
    modeloFijarVariante(0)
    escribir64(e + 64, len)
    ef(e + 72, lf(m + 88))
    escribir64(e + 80, t1 - t0)
    escribir64(e + 16, leer64(e + 16) + len)
    give len
}

// Una pasada de vigilia sobre `len` bytes de texto, línea a línea (cada línea
// con su '\n', como si se tecleara). Devuelve los bits/byte de la pasada.
expose flow aprPasada(m: Int, texto: Int, len: Int) => Float {
    hold e = est()
    hold w = trabajo()
    change bytes = 0
    change bits = 0.0
    change ciclos = 0
    change ini = 0
    during ini < len {
        change fin = ini
        during fin < len && leer8(texto + fin) != 10 { fin += 1 }
        change n = fin - ini
        when n > 4000 { n = 4000 }
        each i among 0..n { escribir8(w + i, leer8(texto + ini + i)) }
        bytes += aprLineaBytes(m, w, n)
        bits += lf(e + 72)
        ciclos += leer64(e + 80)
        ini = fin + 1
    }
    escribir64(e + 64, bytes)
    ef(e + 72, bits)
    escribir64(e + 80, ciclos)
    when bytes == 0 { give 0.0 }
    give bits / Float(bytes)
}

// bits/byte congelados de un texto (línea a línea, cada una un documento con su
// '\n'), sin aprender ni autocompletar. Solo cambian métricas y el estado
// transitorio de la corteza.
expose flow aprMedirCongelado(m: Int, texto: Int, len: Int) => Float {
    hold w = trabajo()
    metricasReiniciar(m)
    change ini = 0
    during ini < len {
        change fin = ini
        during fin < len && leer8(texto + fin) != 10 { fin += 1 }
        change n = fin - ini
        when n > 4000 { n = 4000 }
        each i among 0..n { escribir8(w + i, leer8(texto + ini + i)) }
        escribir8(w + n, 10)
        modeloMedirCongelado(m, w, n + 1)
        ini = fin + 1
    }
    when leer64(m + 80) == 0 { give 0.0 }
    give lf(m + 88) / Float(leer64(m + 80))
}

// ms por byte con tres decimales (ciclos de TSC para `bytes` bytes).
flow imprimirMsPorByte(ciclos: Int, bytes: Int) {
    when bytes < 1 { give }
    hold cpm = tscCiclosPorMs()
    hold d1000 = ciclos * 1000 / cpm / bytes
    kprintEntero(d1000 / 1000)
    kprintByte(46)
    when d1000 % 1000 < 100 { kprintByte(48) }
    when d1000 % 1000 < 10 { kprintByte(48) }
    kprintEntero(d1000 % 1000)
}

// Línea tecleada (`nb` bytes UTF-8 en `bytes`, con sitio para uno más): la
// aprende, lo dice y vuelve a mostrar lo tecleado para que el completado siga
// a continuación (`linea`: los `n` puntos de código tecleados).
expose flow aprTeclear(m: Int, bytes: Int, nb: Int, linea: Int, n: Int) {
    hold e = est()
    kprintByte(10)
    hold total = aprLineaBytes(m, bytes, nb)
    kprint(cadena("  aprendido: "))
    kprintEntero(total)
    kprint(cadena(" bytes, "))
    kprintDecimal(lf(e + 72) / Float(total), 3)
    kprint(cadena(" bits/byte  ["))
    imprimirMsPorByte(leer64(e + 80), total)
    kprint(cadena(" ms por byte; sin guardar "))
    kprintEntero(leer64(e + 16))
    kprintln(cadena(" bytes]"))
    kprint(cadena("  "))
    each i among 0..n { kprintCaracter(leer64(linea + i * 8)) }
}

// ---- :guardar --------------------------------------------------------------

flow letra(r: Int) {
    when r < 0 { kprint(cadena("-")) } otherwise { encaLetraRanura(r) }
}

// Evalúa A y B congeladas, compara con la referencia y, si no empeora más que
// el umbral, guarda en la otra ranura. 1 = guardado, 0 = rechazado por la
// protección, -1 = error.
expose flow aprGuardar(m: Int) => Int {
    hold e = est()
    when leer64(e + 56) != 1 {
        kprintln(cadena("  guardar: no hay ranuras de ENCA (sin partición de datos)"))
        give -1
    }
    hold cpm = tscCiclosPorMs()
    hold t0 = rdtsc()
    encaEvaluarSilencioso(m)
    hold t1 = rdtsc()
    hold r = encaResultado(1)
    hold bA = lf(r)
    hold bB = lf(r + 32)
    hold dA = bA - lf(e + 40)
    hold dB = bB - lf(e + 48)
    ef(e + 88, dB)
    ef(e + 96, dA)
    kprint(cadena("  prueba B congelada: "))
    kprintDecimal(bB, 4)
    kprint(cadena(" bits/byte (guardada "))
    kprintDecimal(lf(e + 48), 4)
    kprint(cadena("), delta B = "))
    kprintDecimal(dB, 4)
    kprint(cadena("; prueba A: "))
    kprintDecimal(bA, 4)
    kprint(cadena(" (delta A = "))
    kprintDecimal(dA, 4)
    kprint(cadena("); evaluación "))
    kprintEntero((t1 - t0) / cpm)
    kprintln(cadena(" ms"))
    when dB > lf(e + 8) {
        kprint(cadena("  no se guarda: la prueba B empeora "))
        kprintDecimal(dB, 4)
        kprint(cadena(" bits/byte (umbral "))
        kprintDecimal(lf(e + 8), 4)
        kprintln(cadena("); use :deshacer para volver al último estado guardado"))
        give 0
    }
    hold cap = encaTamEstado()
    hold buf = montonReservar(cap + 1024)
    when buf == 0 {
        kprintln(cadena("  guardar: sin memoria para el búfer del estado"))
        give -1
    }
    hold ts0 = rdtsc()
    hold total = encaSerializar(m, buf, encaEntrenados())
    when total == 0 {
        kprintln(cadena("  guardar: la configuración del modelo no es la C5"))
        montonLiberar(buf)
        give -1
    }
    encaMetricasAlBufer(buf)
    hold ts1 = rdtsc()
    hold actual = leer64(e + 24)
    change destino = 0
    when actual == 0 { destino = 1 }
    when actual < 0 {
        when !ckptPreparar(CKPT_ENCA, total) {
            kprintln(cadena("  guardar: no se pudieron crear ENCA_A.BIN y ENCA_B.BIN"))
            montonLiberar(buf)
            give -1
        }
    }
    hold paso = leer64(e + 32) + 1
    hold t2 = rdtsc()
    hold bien = ckptGuardarEn(CKPT_ENCA, destino, paso, buf, total)
    hold t3 = rdtsc()
    montonLiberar(buf)
    when !bien {
        kprintln(cadena("  guardar: FALLÓ la escritura del estado"))
        give -1
    }
    escribir64(e + 24, destino)
    escribir64(e + 32, paso)
    ef(e + 40, bA)
    ef(e + 48, bB)
    escribir64(e + 16, 0)
    kprint(cadena("  guardado: paso "))
    kprintEntero(paso)
    kprint(cadena(" en la ranura "))
    letra(destino)
    kprint(cadena(", "))
    kprintEntero(total)
    kprint(cadena(" bytes; serializar "))
    kprintEntero((ts1 - ts0) / cpm)
    kprint(cadena(" ms; escritura con CRC32C y vaciado "))
    encaImprimirMsMBs(total, t3 - t2)
    kprintByte(10)
    ckptImprimirDesglose(ts1 - ts0)
    give 1
}

// Solo medida: evalúa A y B congeladas y devuelve (mezcla B actual - guardada),
// sin guardar nada. También deja el delta en +88 (B) y +96 (A).
expose flow aprDeltaB(m: Int) => Float {
    hold e = est()
    encaEvaluarSilencioso(m)
    hold r = encaResultado(1)
    ef(e + 88, lf(r + 32) - lf(e + 48))
    ef(e + 96, lf(r) - lf(e + 40))
    give lf(e + 88)
}

// ---- :deshacer -------------------------------------------------------------

// 1 = hecho, 0 = no hay a dónde volver, -1 = error.
expose flow aprDeshacer(m: Int) => Int {
    hold e = est()
    when leer64(e + 56) != 1 {
        kprintln(cadena("  deshacer: no hay ranuras de ENCA (sin partición de datos)"))
        give -1
    }
    hold cpm = tscCiclosPorMs()
    hold actual = leer64(e + 24)
    hold paso = leer64(e + 32)
    hold pend = leer64(e + 16)
    change origen = actual
    change reescribir = false
    when pend > 0 {
        when actual < 0 {
            kprintln(cadena("  deshacer: no hay ningún estado guardado al que volver"))
            give 0
        }
        kprint(cadena("  deshacer: se descartan "))
        kprintEntero(pend)
        kprint(cadena(" bytes aprendidos sin guardar; se recarga la ranura "))
        letra(actual)
        kprint(cadena(", paso "))
        kprintEntero(paso)
        kprintByte(10)
    } otherwise {
        when actual < 0 {
            kprintln(cadena("  deshacer: no hay a dónde volver (ninguna ranura guardada)"))
            give 0
        }
        hold otra = 1 - actual
        hold pasoOtra = ckptPasoRanura(CKPT_ENCA, otra)
        when pasoOtra < 0 {
            kprint(cadena("  deshacer: no hay a dónde volver (solo la ranura "))
            letra(actual)
            kprintln(cadena(" es válida y no hay cambios sin guardar)"))
            give 0
        }
        when ckptCrcRanura(CKPT_ENCA, otra) == ckptCrcRanura(CKPT_ENCA, actual) {
            kprint(cadena("  deshacer: no hay a dónde volver (las dos ranuras guardan el mismo estado: "))
            letra(actual)
            kprint(cadena(" paso "))
            kprintEntero(paso)
            kprint(cadena(", "))
            letra(otra)
            kprint(cadena(" paso "))
            kprintEntero(pasoOtra)
            kprintln(cadena(")"))
            give 0
        }
        origen = otra
        reescribir = true
        kprint(cadena("  deshacer: sin cambios pendientes; se vuelve a la versión anterior, ranura "))
        letra(otra)
        kprint(cadena(", paso "))
        kprintEntero(pasoOtra)
        kprintByte(10)
    }
    hold cap = encaTamEstadoMax()
    hold buf = montonReservar(cap + 1024)
    when buf == 0 {
        kprintln(cadena("  deshacer: sin memoria para el búfer del estado"))
        give -1
    }
    hold t0 = rdtsc()
    hold pasoLeido = ckptCargarRanura(CKPT_ENCA, origen, buf)
    hold t1 = rdtsc()
    when pasoLeido < 0 {
        kprintln(cadena("  deshacer: no se pudo leer la ranura (cabecera o CRC inválidos)"))
        montonLiberar(buf)
        give -1
    }
    when !encaDeserializar(m, buf) {
        kprintln(cadena("  deshacer: el estado no es compatible con el modelo"))
        montonLiberar(buf)
        give -1
    }
    kprint(cadena("  ranura "))
    letra(origen)
    kprint(cadena(" leída y verificada (formato "))
    kprintEntero(ckptVersionCargada(CKPT_ENCA))
    kprint(cadena(") en "))
    kprintEntero((t1 - t0) / cpm)
    kprintln(cadena(" ms; se comprueba la evaluación contra su cabecera..."))
    // Igual que el hito 17 tras cargar: la evaluación debe ser idéntica.
    hold t2 = rdtsc()
    encaEvaluarSilencioso(m)
    hold dif = encaCompararMetricas(buf)
    kprint(cadena("  evaluación "))
    kprintEntero((rdtsc() - t2) / cpm)
    // Un estado de la versión 1 (corteza f64) no puede dar la misma evaluación bit a bit.
    when dif != 0 && !encaEstadoAntiguo(buf) {
        kprint(cadena(" ms: DIFERENTE de la cabecera ("))
        kprintEntero(dif)
        kprintln(cadena(" métricas); no se reescribe nada"))
        montonLiberar(buf)
        give -1
    }
    when dif != 0 {
        kprintln(cadena(" ms: estado v1 (corteza f64 convertida): evaluación distinta de la cabecera, como se espera"))
    } otherwise {
        kprintln(cadena(" ms: idéntica a la cabecera"))
    }
    // La referencia es la cabecera de lo restaurado (mezcla A y B).
    ef(e + 40, floatDeBits(leer64(buf + (ENCA_CAB_METRICAS) * 8)))
    ef(e + 48, floatDeBits(leer64(buf + (ENCA_CAB_METRICAS + 8) * 8)))
    when reescribir {
        // Para que el deshacer sobreviva a un reinicio: la versión anterior
        // pasa a ser la más reciente (paso + 1, en la ranura de la que se viene).
        hold nuevo = paso + 1
        hold t3 = rdtsc()
        hold bien = ckptGuardarEn(CKPT_ENCA, actual, nuevo, buf, leer64(buf + 96))
        hold t4 = rdtsc()
        when !bien {
            kprintln(cadena("  deshacer: FALLÓ la reescritura de la versión restaurada"))
            montonLiberar(buf)
            give -1
        }
        escribir64(e + 32, nuevo)
        kprint(cadena("  restaurada: reescrita como paso "))
        kprintEntero(nuevo)
        kprint(cadena(" en la ranura "))
        letra(actual)
        kprint(cadena(" ("))
        kprintEntero((t4 - t3) / cpm)
        kprintln(cadena(" ms); el próximo arranque la carga"))
    }
    montonLiberar(buf)
    escribir64(e + 16, 0)
    give 1
}

// ---- comandos ---------------------------------------------------------------

flow imprimirEstado() {
    hold e = est()
    kprint(cadena("  aprender "))
    when leer64(e) == 0 { kprint(cadena("si")) } otherwise { kprint(cadena("no")) }
    kprint(cadena("  modo "))
    kprintByte(97 + leer64(e + 104))
    kprint(cadena("  umbral "))
    kprintDecimal(lf(e + 8), 4)
    kprint(cadena(" bits/byte  sin guardar "))
    kprintEntero(leer64(e + 16))
    kprint(cadena(" bytes  ranura "))
    letra(leer64(e + 24))
    kprint(cadena(" paso "))
    kprintEntero(leer64(e + 32))
    kprint(cadena("  B guardada "))
    kprintDecimal(lf(e + 48), 4)
    kprintln(cadena(" bits/byte"))
}

flow ayudaAprender() {
    kprintln(cadena("  :aprender si|no  aprender de cada línea tecleada (defecto si)"))
    kprintln(cadena("  :guardar   guardar si la prueba B no empeora más que el umbral"))
    kprintln(cadena("  :deshacer  descartar lo aprendido (o volver a la versión anterior)"))
    kprintln(cadena("  :modoaprender a|b|c|d  a todo, b sin mezclador, c solo hipocampo, d mezclador a 1/10"))
    kprintln(cadena("  :umbral x  bits/byte que puede empeorar la prueba B al guardar"))
}

// Ejecuta la línea de comando si es de las de este módulo (:aprender,
// :guardar, :deshacer, :umbral) o si amplía :ver / :ayuda. false si no.
expose flow aprComando(linea: Int, n: Int) => Bool {
    hold e = est()
    hold m = encaModelo()
    when m == 0 { give false }
    change fin = 1
    during fin < n && leer64(linea + fin * 8) != 32 { fin += 1 }
    hold pal = linea + 8
    hold np = fin - 1
    change a = fin
    during a < n && leer64(linea + a * 8) == 32 { a += 1 }
    change b = n
    during b > a && leer64(linea + (b - 1) * 8) == 32 { b -= 1 }
    when np == 0 { give false }
    when mzEsPalabra(pal, np, cadena("ver")) {
        mzComando(linea, n)
        imprimirEstado()
        give true
    }
    when mzEsPalabra(pal, np, cadena("ayuda")) {
        mzComando(linea, n)
        ayudaAprender()
        give true
    }
    when mzEsPalabra(pal, np, cadena("aprender")) {
        when b - a == 2 && mzMinuscula(leer64(linea + a * 8)) == 115 && mzMinuscula(leer64(linea + (a + 1) * 8)) == 105 {
            escribir64(e, 0)
            kprintln(cadena("  aprender = si"))
        } otherwise when b - a == 2 && mzMinuscula(leer64(linea + a * 8)) == 110 && mzMinuscula(leer64(linea + (a + 1) * 8)) == 111 {
            escribir64(e, 1)
            kprintln(cadena("  aprender = no"))
        } otherwise {
            kprintln(cadena("  error: :aprender espera si o no (no cambia nada)"))
        }
        give true
    }
    when mzEsPalabra(pal, np, cadena("modoaprender")) {
        change v = -1
        when b - a == 1 { v = mzMinuscula(leer64(linea + a * 8)) - 97 }
        when v < 0 || v > 3 {
            kprintln(cadena("  error: :modoaprender espera a, b, c o d (no cambia nada)"))
        } otherwise {
            escribir64(e + 104, v)
            kprint(cadena("  modoaprender = "))
            kprintByte(97 + v)
            kprintByte(10)
        }
        give true
    }
    when mzEsPalabra(pal, np, cadena("umbral")) {
        hold ok = reservar(8, 8)
        hold v = mzLeerDecimal(linea, a, b, ok)
        when leer64(ok) == 0 || v > 100.0 {
            kprintln(cadena("  error: :umbral espera un decimal entre 0 y 100 (no cambia nada)"))
        } otherwise {
            ef(e + 8, v)
            kprint(cadena("  umbral = "))
            kprintDecimal(v, 4)
            kprintln(cadena(" bits/byte"))
        }
        give true
    }
    when mzEsPalabra(pal, np, cadena("guardar")) {
        aprGuardar(m)
        give true
    }
    when mzEsPalabra(pal, np, cadena("deshacer")) {
        aprDeshacer(m)
        give true
    }
    give false
}
