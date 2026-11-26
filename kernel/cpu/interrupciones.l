// Entrada común de todas las interrupciones y excepciones.
//
// El compilador genera los 256 stubs: cada uno apila un código de error (0
// si la CPU no pone uno), el número de vector y los 15 registros generales,
// y llama a `kinterrupcion(marco)`. Al volver restaura todo y hace IRETQ.
//
// Marco (desplazamientos sobre `marco`):
//   0 R15  8 R14  16 R13  24 R12  32 R11  40 R10  48 R9  56 R8
//   64 RDI  72 RSI  80 RBP  88 RBX  96 RDX  104 RCX  112 RAX
//   120 vector  128 código de error  136 RIP  144 CS  152 RFLAGS
//   160 RSP  168 SS
//
// Los manejadores no usan Float: los registros XMM no se guardan aquí.

take nucleo.cpu
take nucleo.mem
take lib.consola
take dispositivos.pic
take dispositivos.apic
take dispositivos.teclado
take tiempo.temporizador
take cpu.smp

expose fixed MARCO_VECTOR = 120
expose fixed MARCO_ERROR = 128
expose fixed MARCO_RIP = 136
expose fixed MARCO_CS = 144
expose fixed MARCO_RFLAGS = 152
expose fixed MARCO_RSP = 160

// Contador de #BP atendidos (para la prueba del hito 3).
flow estado() => Int { give reservar(8, 8) }

expose flow interrupcionesPuntosDeParada() => Int {
    give leer64(estado())
}

flow nombreExcepcion(v: Int) => Int {
    when v == 0 { give cadena("#DE división") }
    when v == 1 { give cadena("#DB depuración") }
    when v == 2 { give cadena("NMI") }
    when v == 3 { give cadena("#BP punto de parada") }
    when v == 4 { give cadena("#OF desbordamiento") }
    when v == 5 { give cadena("#BR límites") }
    when v == 6 { give cadena("#UD instrucción inválida") }
    when v == 7 { give cadena("#NM sin FPU") }
    when v == 8 { give cadena("#DF doble falta") }
    when v == 10 { give cadena("#TS TSS inválida") }
    when v == 11 { give cadena("#NP segmento ausente") }
    when v == 12 { give cadena("#SS pila") }
    when v == 13 { give cadena("#GP protección general") }
    when v == 14 { give cadena("#PF fallo de página") }
    when v == 16 { give cadena("#MF x87") }
    when v == 17 { give cadena("#AC alineación") }
    when v == 18 { give cadena("#MC verificación de máquina") }
    when v == 19 { give cadena("#XM SIMD") }
    when v == 20 { give cadena("#VE virtualización") }
    when v == 21 { give cadena("#CP protección de control") }
    give cadena("excepción reservada")
}

flow campo(nombre: Int, valor: Int) {
    kprint(nombre)
    kprintHex(valor)
    kprintByte(10)
}

flow excepcion(marco: Int) {
    hold v = leer64(marco + MARCO_VECTOR)
    kprint(cadena("\n*** excepción "))
    kprintEntero(v)
    kprint(cadena(": "))
    kprintln(nombreExcepcion(v))
    campo(cadena("  error  "), leer64(marco + MARCO_ERROR))
    campo(cadena("  RIP    "), leer64(marco + MARCO_RIP))
    campo(cadena("  CS     "), leer64(marco + MARCO_CS))
    campo(cadena("  RFLAGS "), leer64(marco + MARCO_RFLAGS))
    campo(cadena("  RSP    "), leer64(marco + MARCO_RSP))
    when v == 14 { campo(cadena("  CR2    "), leerCr2()) }
    // #BP es una trampa: se continúa tras el INT3.
    when v == 3 {
        escribir64(estado(), leer64(estado()) + 1)
        give
    }
    kprintln(cadena("*** sistema detenido"))
    during true {
        cli()
        hlt()
    }
}

flow kinterrupcion(marco: Int) {
    hold v = leer64(marco + MARCO_VECTOR)
    when v < 32 {
        excepcion(marco)
        give
    }
    when v == VECTOR_TEMPORIZADOR {
        temporizadorTic()
        lapicFin()
        give
    }
    when v == VECTOR_TECLADO {
        tecladoInterrupcion()
        lapicFin()
        give
    }
    when v == VECTOR_ESPURIO { give }
    // Entrada de un procesador secundario recién despertado (cpu/smp.l).
    when v == VECTOR_ENTRADA_AP {
        smpEntradaAp()
        give
    }
    when v >= 32 && v < 48 {
        // IRQ del PIC 8259 (deberían estar enmascaradas): fin de interrupción.
        picFinInterrupcion(v - 32)
        give
    }
}
