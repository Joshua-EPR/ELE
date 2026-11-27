// Hito 18: generación de ENCA sin bucles (muestreo con penalización de
// n-gramas) frente al completado voraz. 20 prompts fijos, 200 bytes cada
// uno, configuración por defecto y semilla fija.
//
// OK si 0/20 generaciones con bucle en muestreo y 20/20 reproducibles con la
// misma semilla. El voraz solo se cuenta, para comparar.

take nucleo.cpu
take nucleo.mem
take lib.consola
take dispositivos.apic
take enca.exp009
take enca.muestreo

fixed GENERAR = 200
fixed SEMILLA = 20261126
fixed PROMPTS = 20
fixed MOSTRAR = 80

flow prompt(i: Int) => Int {
    when i == 0 { give cadena("flow main") }
    when i == 1 { give cadena("expose flow ") }
    when i == 2 { give cadena("hold x = ") }
    when i == 3 { give cadena("each i among ") }
    when i == 4 { give cadena("when ") }
    when i == 5 { give cadena("give ") }
    when i == 6 { give cadena("change ") }
    when i == 7 { give cadena("take ") }
    when i == 8 { give cadena("// ") }
    when i == 9 { give cadena("fixed ") }
    when i == 10 { give cadena("during ") }
    when i == 11 { give cadena("shape ") }
    when i == 12 { give cadena("la memoria ") }
    when i == 13 { give cadena("el modelo ") }
    when i == 14 { give cadena("el hipocampo ") }
    when i == 15 { give cadena("La corteza ") }
    when i == 16 { give cadena("Para entrenar ") }
    when i == 17 { give cadena("expose flow aprender(") }
    when i == 18 { give cadena("otherwise ") }
    give cadena("La red neuronal ")
}

// Genera GENERAR bytes en `salida` (no para en '\n'). Devuelve los ciclos.
flow generar(m: Int, p: Int, salida: Int, voraz: Bool) => Int {
    mzIniciar(m, p + 8, leer64(p))
    hold t0 = rdtsc()
    each k among 0..GENERAR { escribir8(salida + k, mzSiguiente(m, voraz)) }
    give rdtsc() - t0
}

flow iguales(a: Int, b: Int, n: Int) => Bool {
    each i among 0..n {
        when leer8(a + i) != leer8(b + i) { give false }
    }
    give true
}

// Imprime hasta `n` bytes UTF-8 sin romper la pantalla: '\n' -> '¶',
// el resto de controles -> espacio, secuencias inválidas -> '?'.
flow imprimirBytes(buf: Int, n: Int) {
    change falta = 0
    change cp = 0
    each i among 0..n {
        hold b = leer8(buf + i)
        when b < 0x80 {
            when falta != 0 {
                kprintByte(63)
                falta = 0
            }
            when b == 10 {
                kprintCaracter(0xB6)
            } otherwise when b < 32 {
                kprintByte(32)
            } otherwise {
                kprintByte(b)
            }
        } otherwise when b >= 0xC0 {
            when falta != 0 { kprintByte(63) }
            falta = 1
            cp = b & 0x1F
            when b >= 0xE0 {
                falta = 2
                cp = b & 0x0F
            }
            when b >= 0xF0 {
                falta = 3
                cp = b & 0x07
            }
        } otherwise when falta == 0 {
            kprintByte(63)
        } otherwise {
            cp = (cp << 6) | (b & 0x3F)
            falta -= 1
            when falta == 0 { kprintCaracter(cp) }
        }
    }
    when falta != 0 { kprintByte(63) }
}

flow siNo(v: Bool) {
    when v { kprint(cadena("si")) } otherwise { kprint(cadena("no")) }
}

// Milésimas de ms por byte -> "x,yyy".
flow imprimirMs(milesimas: Int) {
    kprintEntero(milesimas / 1000)
    kprintByte(46)
    when milesimas % 1000 < 100 { kprintByte(48) }
    when milesimas % 1000 < 10 { kprintByte(48) }
    kprintEntero(milesimas % 1000)
}


// 1 = OK, 0 = falló, 2 = omitido (sin modelo de ENCA).
expose flow encaHito18() => Int {
    hold m = encaModelo()
    when m == 0 { give 2 }
    mzDefecto()
    mzFijarSemilla(SEMILLA)
    hold a = reservar(256, 8)
    hold b = reservar(256, 8)
    hold v = reservar(256, 8)
    change bucleM = 0
    change bucleV = 0
    change repro = 0
    change ciclosM = 0
    change ciclosV = 0
    kprintln(cadena("generación ENCA: 20 prompts, 200 bytes, defecto + semilla fija (¶ = salto de línea)"))
    each i among 0..PROMPTS {
        hold p = prompt(i)
        mzFijarVoraz(0)
        ciclosM += generar(m, p, a, false)
        generar(m, p, b, false)
        hold igual = iguales(a, b, GENERAR)
        hold lazoM = mzTieneBucle(a, GENERAR)
        mzFijarVoraz(1)
        ciclosV += generar(m, p, v, true)
        hold lazoV = mzTieneBucle(v, GENERAR)
        mzFijarVoraz(0)
        when lazoM { bucleM += 1 }
        when lazoV { bucleV += 1 }
        when igual { repro += 1 }
        kprint(cadena("["))
        kprintEntero(i + 1)
        kprint(cadena("] \""))
        kprint(p)
        kprintln(cadena("\""))
        kprint(cadena("  muestreo: "))
        imprimirBytes(a, MOSTRAR)
        kprintByte(10)
        kprint(cadena("  voraz:    "))
        imprimirBytes(v, MOSTRAR)
        kprintByte(10)
        kprint(cadena("  bucle voraz: "))
        siNo(lazoV)
        kprint(cadena("  bucle muestreo: "))
        siNo(lazoM)
        kprint(cadena("  idéntico con la misma semilla: "))
        siNo(igual)
        kprintByte(10)
    }
    hold cpm = tscCiclosPorMs()
    hold bytes = PROMPTS * GENERAR
    hold mM = ciclosM * 1000 / cpm / bytes
    hold mV = ciclosV * 1000 / cpm / bytes
    kprintln(cadena("---- voraz frente a muestreo (20 prompts x 200 bytes) ----"))
    kprint(cadena("prompts con bucle: voraz "))
    kprintEntero(bucleV)
    kprint(cadena("/20, muestreo "))
    kprintEntero(bucleM)
    kprintln(cadena("/20"))
    kprint(cadena("reproducibles con la misma semilla: "))
    kprintEntero(repro)
    kprintln(cadena("/20"))
    kprint(cadena("ms por byte: voraz "))
    imprimirMs(mV)
    kprint(cadena(", muestreo "))
    imprimirMs(mM)
    kprint(cadena(", sobrecoste del muestreo "))
    when mM >= mV { imprimirMs(mM - mV) } otherwise { kprint(cadena("0,000")) }
    kprintByte(10)
    mzDefecto()
    when bucleM == 0 && repro == PROMPTS { give 1 }
    give 0
}
