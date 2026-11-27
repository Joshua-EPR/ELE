// Diagnóstico de RFLAGS.IF (bit 9): puntos de control del arranque.
//
// En el portátil real hito7 parecía empezar con las interrupciones
// desactivadas tras cargar el modelo hablante. ifPunto guarda (etiqueta, IF)
// en una tabla estática; ifVigilar solo anota el PRIMER punto con IF = 0
// (barato, para bucles). hito7 llama a ifImprimir una vez.

take nucleo.cpu
take nucleo.mem
take lib.consola
take tiempo.reloj
take tiempo.temporizador

fixed MAX_PUNTOS = 48

// +0 puntos guardados, +8 etiqueta del primer IF = 0 (0 = ninguna), +16 vigilados
// con IF = 0, +24 armado (1 tras el sti del hito 6); desde +32: entradas de 16 bytes (etiqueta, IF).
flow tabla() => Int { give reservar(32 + 16 * MAX_PUNTOS, 8) }

// RFLAGS.IF: true con las interrupciones del procesador activadas.
expose flow ifActivo() => Bool { give ((leerRflags() >> 9) & 1) == 1 }

// Desde aquí un IF = 0 cuenta como anómalo (el sti del hito 6 ya se ejecutó).
expose flow ifArmar() { escribir64(tabla() + 24, 1) }

// Anota (etiqueta, IF) y recuerda el primer punto con IF = 0.
expose flow ifPunto(etiqueta: Int) {
    hold t = tabla()
    hold activo = ifActivo()
    when !activo && leer64(t + 24) == 1 && leer64(t + 8) == 0 { escribir64(t + 8, etiqueta) }
    hold n = leer64(t)
    when n >= MAX_PUNTOS { give }
    hold e = t + 32 + n * 16
    escribir64(e, etiqueta)
    when activo { escribir64(e + 8, 1) } otherwise { escribir64(e + 8, 0) }
    escribir64(t, n + 1)
}

// Para bucles: no guarda nada salvo el primer IF = 0.
expose flow ifVigilar(etiqueta: Int) {
    when ifActivo() { give }
    hold t = tabla()
    when leer64(t + 24) != 1 { give }
    when leer64(t + 8) == 0 { escribir64(t + 8, etiqueta) }
    escribir64(t + 16, leer64(t + 16) + 1)
}

// Imprime la tabla (líneas de a 12 puntos) y, si el procesador acepta
// interrupciones, comprueba que el temporizador LAPIC sigue contando.
expose flow ifImprimir() {
    hold t = tabla()
    hold n = leer64(t)
    each i among 0..n {
        when i % 12 == 0 {
            when i > 0 { kprintByte(10) }
            kprint(cadena("IF:"))
        }
        hold e = t + 32 + i * 16
        kprintByte(32)
        kprint(leer64(e))
        kprintByte(61)
        kprintEntero(leer64(e + 8))
    }
    kprintByte(10)
    kprint(cadena("IF: ahora "))
    when ifActivo() { kprint(cadena("1")) } otherwise { kprint(cadena("0")) }
    kprint(cadena(", primer cero en "))
    when leer64(t + 8) == 0 { kprint(cadena("ninguno")) } otherwise { kprint(leer64(t + 8)) }
    kprint(cadena(", vigilados con cero "))
    kprintEntero(leer64(t + 16))
    // Espera 35 ms de reloj de referencia: con IF = 1 el temporizador de
    // 10 ms debe sumar unos 3 tics; con IF = 0 ninguno.
    hold t0 = temporizadorTics()
    relojEsperar(35000)
    kprint(cadena("; tics del temporizador en 35 ms: "))
    hold tics = temporizadorTics() - t0
    kprintEntero(tics)
    // Con el temporizador vivo e IF = 1, un hlt debe despertar en <= 10 ms.
    when ifActivo() && tics > 0 {
        hold r0 = relojNanosegundos()
        hlt()
        kprint(cadena("; hlt despertó en "))
        kprintEntero((relojNanosegundos() - r0) / 1000)
        kprint(cadena(" us"))
    }
    kprintByte(10)
}
