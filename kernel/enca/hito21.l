// Hito 21: prueba de aceptación de "ENCA aprende de lo que escribe el usuario".
// Solo con la opción de arranque enca=prueba21 (sin ella solo se mide, barato,
// el fragmento F con el modelo cargado, para ver que lo aprendido sobrevive a
// un reinicio). Usa las mismas funciones que los comandos de ENCA> (aprPasada,
// aprGuardar, aprDeshacer de enca/aprender.l), no un camino aparte.
//
//  a) F: texto NUEVO (no está en el corpus), código ELE con nombres inventados.
//     bits/byte congelados de F antes.
//  b) F se aprende 5 veces (línea a línea, como si se tecleara): los bits/byte
//     precuenciales deben bajar; los congelados de F bajan; el completado voraz
//     de un prefijo de cada línea de F acierta más bytes.
//  c) :guardar debe pasar la protección y guardar.
//  d) Basura (texto aleatorio PCG) aprendida varias veces: :guardar debe
//     rechazarse; :deshacer recarga lo guardado en c) y la evaluación vuelve a
//     ser idéntica (bits) a la de c).

take nucleo.cpu
take nucleo.mem
take lib.consola
take lib.matf64
take lib.aleatorio
take dispositivos.apic
take enca.matematica
take enca.modelo
take enca.exp009
take enca.muestreo
take enca.aprender

fixed LINEAS_F = 8
fixed PASADAS_F = 5
fixed PASADAS_BASURA = 3
fixed BYTES_BASURA = 3072
fixed PREFIJO = 10

// Fragmento F: 8 líneas de código ELE plausible con nombres inventados.
flow lineaF(i: Int) => Int {
    when i == 0 { give cadena("expose flow zorvalMezclar(lumbre: Int, hebra: Int) => Int {{") }
    when i == 1 { give cadena("    hold quenta = lumbre * 7 + hebra") }
    when i == 2 { give cadena("    change tramuz = quenta - 3") }
    when i == 3 { give cadena("    each pliego among 0..hebra {{ tramuz += pliego * lumbre }}") }
    when i == 4 { give cadena("    when tramuz > 100 {{ give tramuz - 100 }}") }
    when i == 5 { give cadena("    zorvalAnotar(quenta, tramuz)") }
    when i == 6 { give cadena("    give tramuz") }
    give cadena("}}")
}

// F como bloque (+0 longitud, bytes desde +8), construido una vez.
flow textoF() => Int {
    hold p = reservar(1032, 8)
    hold hecho = reservar(8, 8)
    when leer64(hecho) == 1 { give p }
    change n = 0
    each i among 0..LINEAS_F {
        hold c = lineaF(i)
        hold l = leer64(c)
        each j among 0..l { escribir8(p + 8 + n + j, leer8(c + 8 + j)) }
        n += l
        escribir8(p + 8 + n, 10)
        n += 1
    }
    escribir64(p, n)
    escribir64(hecho, 1)
    give p
}

// Basura: BYTES_BASURA bytes imprimibles al azar (PCG), con '\n' cada 64.
flow textoBasura() => Int {
    hold p = reservar(BYTES_BASURA + 8, 8)
    hold g = reservar(16, 8)
    pcgSembrar(g, 777, 54)
    each i among 0..BYTES_BASURA {
        when i % 64 == 63 {
            escribir8(p + 8 + i, 10)
        } otherwise {
            escribir8(p + 8 + i, 32 + pcgSiguiente(g) % 95)
        }
    }
    escribir64(p, BYTES_BASURA)
    give p
}

// Completado voraz del resto de cada línea de F a partir de sus primeros
// PREFIJO bytes: bytes acertados seguidos desde el inicio del resto.
// Escribe en `objetivo` los bytes que había que acertar.
flow coincidenciasF(m: Int, objetivo: Int) => Int {
    hold t = textoF()
    hold len = leer64(t)
    change ini = 0
    change coin = 0
    change total = 0
    during ini < len {
        change fin = ini
        during fin < len && leer8(t + 8 + fin) != 10 { fin += 1 }
        hold n = fin - ini
        when n > PREFIJO + 3 {
            mzIniciar(m, t + 8 + ini, PREFIJO)
            hold resto = n - PREFIJO
            change sigue = true
            each k among 0..resto {
                hold b = mzSiguiente(m, true)
                when sigue && b == leer8(t + 8 + ini + PREFIJO + k) {
                    coin += 1
                } otherwise {
                    sigue = false
                }
            }
            total += resto
        }
        ini = fin + 1
    }
    escribir64(objetivo, total)
    give coin
}

flow congeladoF(m: Int) => Float {
    hold t = textoF()
    give aprMedirCongelado(m, t + 8, leer64(t))
}

// Sin la opción de arranque: mide F con el modelo cargado.
expose flow encaMedirF() {
    hold m = encaModelo()
    when m == 0 { give }
    hold b = congeladoF(m)
    kprint(cadena("hito 21: F congelado "))
    kprintDecimal(b, 6)
    kprint(cadena(" bits/byte (bits "))
    kprintHex(bitsDeFloat(b))
    kprintln(cadena(")"))
}

flow marca(ok: Bool, texto: Int) {
    when ok { kprint(cadena("  [ok] ")) } otherwise { kprint(cadena("  [FALLO] ")) }
    kprintln(texto)
}

// Estudio de variantes del aprendizaje (enca=estudio21): para a, b, c y d,
// desde el mismo estado guardado, delta B tras F x1 y x5, F congelado antes y
// después, completado voraz de F, y delta B tras basura x1 y x3. Cada medida
// termina con :deshacer (recarga el estado guardado).
expose flow encaEstudio21() {
    hold m = encaModelo()
    mzDefecto()
    hold t = textoF()
    hold g = textoBasura()
    hold objetivo = reservar(8, 8)
    kprintln(cadena("estudio 21: variante | dB F x1 | dB F x5 | F antes | F después | voraz | dB basura x1 | dB basura x3"))
    each v among 0..4 {
        aprFijarVariante(v)
        hold antes = congeladoF(m)
        hold c0 = coincidenciasF(m, objetivo)
        aprPasada(m, t + 8, leer64(t))
        hold d1 = aprDeltaB(m)
        each i among 1..PASADAS_F { aprPasada(m, t + 8, leer64(t)) }
        hold d5 = aprDeltaB(m)
        hold despues = congeladoF(m)
        hold c5 = coincidenciasF(m, objetivo)
        aprDeshacer(m)
        aprPasada(m, g + 8, leer64(g))
        hold b1 = aprDeltaB(m)
        aprPasada(m, g + 8, leer64(g))
        aprPasada(m, g + 8, leer64(g))
        hold b3 = aprDeltaB(m)
        aprDeshacer(m)
        kprint(cadena("estudio 21: "))
        kprintByte(97 + v)
        kprint(cadena(" | "))
        kprintDecimal(d1, 4)
        kprint(cadena(" | "))
        kprintDecimal(d5, 4)
        kprint(cadena(" | "))
        kprintDecimal(antes, 4)
        kprint(cadena(" | "))
        kprintDecimal(despues, 4)
        kprint(cadena(" | "))
        kprintEntero(c0)
        kprint(cadena("->"))
        kprintEntero(c5)
        kprint(cadena("/"))
        kprintEntero(leer64(objetivo))
        kprint(cadena(" | "))
        kprintDecimal(b1, 4)
        kprint(cadena(" | "))
        kprintDecimal(b3, 4)
        kprintByte(10)
    }
    aprFijarVariante(0)
}

// 1 = OK, 0 = falló, 2 = omitido (sin modelo o sin ranuras).
expose flow encaHito21() => Int {
    hold m = encaModelo()
    when m == 0 { give 2 }
    when aprPaso() <= 0 && aprRanura() < 0 {
        kprintln(cadena("hito 21: no hay ranuras guardadas de ENCA (ENCA_A.BIN / ENCA_B.BIN)"))
        give 2
    }
    mzDefecto()
    hold cpm = tscCiclosPorMs()
    hold t = textoF()
    hold flen = leer64(t)
    kprint(cadena("hito 21: ENCA aprende de lo que se teclea. F = "))
    kprintEntero(flen)
    kprint(cadena(" bytes en "))
    kprintEntero(LINEAS_F)
    kprint(cadena(" líneas; umbral de :guardar "))
    kprintDecimal(aprUmbral(), 4)
    kprint(cadena(" bits/byte; estado de partida: ranura "))
    encaLetraRanura(aprRanura())
    kprint(cadena(" paso "))
    kprintEntero(aprPaso())
    kprint(cadena(", B guardada "))
    kprintDecimal(aprReferenciaB(), 4)
    kprintln(cadena(" bits/byte"))
    hold pasoInicial = aprPaso()
    change fallos = 0

    // a) F antes.
    hold objetivo = reservar(8, 8)
    hold antes = congeladoF(m)
    hold coinAntes = coincidenciasF(m, objetivo)
    hold meta = leer64(objetivo)
    kprint(cadena("a) F congelado antes: "))
    kprintDecimal(antes, 4)
    kprint(cadena(" bits/byte; completado voraz del resto de cada línea desde "))
    kprintEntero(PREFIJO)
    kprint(cadena(" bytes: "))
    kprintEntero(coinAntes)
    kprint(cadena("/"))
    kprintEntero(meta)
    kprintln(cadena(" bytes"))

    // b) Aprender F 5 veces.
    hold pasadas = reservar(8 * PASADAS_F, 8)
    change bytesAprendidos = 0
    change ciclosAprendidos = 0
    each i among 0..PASADAS_F {
        hold bits = aprPasada(m, t + 8, flen)
        ef(pasadas + i * 8, bits)
        bytesAprendidos += aprBytesUltima()
        ciclosAprendidos += aprCiclosUltima()
        kprint(cadena("b) pasada "))
        kprintEntero(i + 1)
        kprint(cadena(": "))
        kprintDecimal(bits, 4)
        kprint(cadena(" bits/byte precuenciales ("))
        kprintEntero(aprBytesUltima())
        kprint(cadena(" bytes)"))
        // Datos para el umbral: cuánto empeora B tras cada pasada.
        when i == 0 || i == 1 || i == PASADAS_F - 1 {
            kprint(cadena("; delta B congelado "))
            kprintDecimal(aprDeltaB(m), 4)
        }
        kprintByte(10)
    }
    hold despues = congeladoF(m)
    hold coinDespues = coincidenciasF(m, objetivo)
    kprint(cadena("b) F congelado después: "))
    kprintDecimal(despues, 4)
    kprint(cadena(" bits/byte; completado voraz: "))
    kprintEntero(coinDespues)
    kprint(cadena("/"))
    kprintEntero(meta)
    kprint(cadena(" bytes; sin guardar "))
    kprintEntero(aprSinGuardar())
    kprint(cadena(" bytes; aprender "))
    kprintDecimal(Float(ciclosAprendidos) / Float(cpm) / Float(bytesAprendidos), 4)
    kprintln(cadena(" ms por byte"))
    hold bajan = lf(pasadas + 8) < lf(pasadas) && lf(pasadas + (PASADAS_F - 1) * 8) < lf(pasadas + 8)
    marca(bajan, cadena("los bits/byte precuenciales bajan de la pasada 1 a la 2 y de la 2 a la 5"))
    when !bajan { fallos += 1 }
    marca(despues < antes, cadena("bits/byte congelados de F: después < antes"))
    when !(despues < antes) { fallos += 1 }
    marca(coinDespues > coinAntes, cadena("el completado voraz de F acierta más bytes"))
    when !(coinDespues > coinAntes) { fallos += 1 }
    marca(aprSinGuardar() > 0, cadena("la cuenta de bytes sin guardar sube"))
    when aprSinGuardar() <= 0 { fallos += 1 }

    // c) :guardar debe pasar.
    kprintln(cadena("c) :guardar tras aprender F"))
    hold rc = aprGuardar(m)
    hold deltaC = aprUltimoDeltaB()
    hold bC = aprReferenciaB()
    hold pasoC = aprPaso()
    marca(rc == 1 && pasoC == pasoInicial + 1 && aprSinGuardar() == 0, cadena(":guardar pasa la protección y guarda (paso + 1, sin guardar = 0)"))
    when !(rc == 1 && pasoC == pasoInicial + 1 && aprSinGuardar() == 0) { fallos += 1 }
    hold fC = congeladoF(m)

    // d) Basura.
    hold g = textoBasura()
    each i among 0..PASADAS_BASURA {
        hold bits = aprPasada(m, g + 8, leer64(g))
        kprint(cadena("d) basura, pasada "))
        kprintEntero(i + 1)
        kprint(cadena(": "))
        kprintDecimal(bits, 4)
        kprint(cadena(" bits/byte precuenciales ("))
        kprintEntero(aprBytesUltima())
        kprint(cadena(" bytes); delta B congelado "))
        kprintDecimal(aprDeltaB(m), 4)
        kprintByte(10)
    }
    kprint(cadena("d) sin guardar "))
    kprintEntero(aprSinGuardar())
    kprintln(cadena(" bytes; :guardar debe rechazarse"))
    hold rd = aprGuardar(m)
    hold deltaD = aprUltimoDeltaB()
    marca(rd == 0 && deltaD > aprUmbral(), cadena(":guardar rechaza la basura (delta B > umbral)"))
    when !(rd == 0 && deltaD > aprUmbral()) { fallos += 1 }
    marca(aprPaso() == pasoC, cadena("el paso guardado no cambió"))
    when aprPaso() != pasoC { fallos += 1 }
    kprintln(cadena("d) :deshacer"))
    hold rr = aprDeshacer(m)
    marca(rr == 1 && aprSinGuardar() == 0, cadena(":deshacer recarga lo guardado en c)"))
    when !(rr == 1 && aprSinGuardar() == 0) { fallos += 1 }
    hold iguales = bitsDeFloat(aprReferenciaB()) == bitsDeFloat(bC) && aprPaso() == pasoC
    marca(iguales, cadena("la evaluación B tras :deshacer es idéntica (bits) a la de c)"))
    when !iguales { fallos += 1 }
    hold fD = congeladoF(m)
    marca(bitsDeFloat(fD) == bitsDeFloat(fC), cadena("F congelado idéntico (bits) al de c)"))
    when bitsDeFloat(fD) != bitsDeFloat(fC) { fallos += 1 }
    kprint(cadena("hito 21: delta B de F "))
    kprintDecimal(deltaC, 4)
    kprint(cadena(" (guardado), de la basura "))
    kprintDecimal(deltaD, 4)
    kprint(cadena(" (rechazado), umbral "))
    kprintDecimal(aprUmbral(), 4)
    kprintByte(10)
    kprint(cadena("hito 21: F congelado "))
    kprintDecimal(fD, 6)
    kprint(cadena(" bits/byte (bits "))
    kprintHex(bitsDeFloat(fD))
    kprintln(cadena(")"))
    when fallos == 0 { give 1 }
    kprint(cadena("hito 21 FALLÓ: "))
    kprintEntero(fallos)
    kprintln(cadena(" comprobaciones no se cumplen (ver [FALLO] arriba)"))
    give 0
}
