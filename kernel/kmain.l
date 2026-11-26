// Punto de entrada del kernel ELE. Limine salta aquí en modo largo, con
// paginación activa, interrupciones desactivadas y una pila válida.
// Se compila con herramientas/construir.ps1 (--target kernel --lib .).

take nucleo.cpu
take nucleo.mem
take arranque.limine
take lib.consola
take dispositivos.pantalla
take dispositivos.pic
take cpu.gdt
take cpu.idt
take cpu.interrupciones
take cpu.caracteristicas
take mem.fisica
take mem.paginacion
take mem.monton
take dispositivos.acpi
take dispositivos.apic
take dispositivos.teclado
take tiempo.reloj
take tiempo.temporizador
take cpu.smp
take bench.sgemm

flow kmain() {
    consolaIniciar()
    kprintln(cadena("ELE kernel OK"))

    // Hito 2: framebuffer, fuente 8x16 y kprint.
    when !arranqueRevisionAceptada() {
        kprintln(cadena("aviso: Limine no aceptó la revisión base 3"))
    }
    when consolaTienePantalla() {
        kprint(cadena("pantalla: "))
        kprintEntero(pantallaAncho())
        kprint(cadena("x"))
        kprintEntero(pantallaAlto())
        kprintln(cadena(" a 32 bpp"))
    } otherwise {
        kprintln(cadena("pantalla: sin framebuffer"))
    }
    kprint(cadena("HHDM en "))
    kprintHex(arranqueHhdm())
    kprintByte(10)
    kprintln(cadena("Hola desde ELE: ñandú, acción, pingüino (latam)."))
    kprintln(cadena("hito 2 OK"))

    // Hito 3: GDT + TSS, IDT con 256 stubs, excepciones.
    gdtIniciar()
    kprintln(cadena("GDT y TSS cargadas"))
    picReprogramarYEnmascarar()
    idtIniciar()
    kprintln(cadena("IDT cargada; probando INT3..."))
    int3()
    when interrupcionesPuntosDeParada() == 1 {
        kprintln(cadena("hito 3 OK"))
    } otherwise {
        kprintln(cadena("hito 3 FALLÓ: el #BP no volvió"))
    }

    hito4()
    hito5()
    hito6()
    hito8()
    hito9()
    hito7()

    during true {
        cli()
        hlt()
    }
}

// Hito 4: memoria física, paginación propia y montón.
flow hito4() {
    when !memFisicaIniciar() {
        kprintln(cadena("hito 4 FALLÓ: sin mapa de memoria"))
        give
    }
    kprint(cadena("memoria: "))
    kprintEntero(memFisicaLibres() * MARCO / 1048576)
    kprint(cadena(" MiB libres de "))
    kprintEntero(memFisicaTotales() * MARCO / 1048576)
    kprintln(cadena(" MiB"))
    when !pagIniciar() {
        kprintln(cadena("hito 4 FALLÓ: no se pudo construir el PML4"))
        give
    }
    kprint(cadena("paginación propia activa, CR3 = "))
    kprintHex(leerCr3())
    kprintByte(10)

    montonIniciar()
    hold a = montonReservar(100)
    hold b = montonReservar(5000)
    hold c = montonReservar(40)
    escribir64(a, 11)
    escribir64(b + 4992, 22)
    escribir64(c, 33)
    montonLiberar(b)
    hold d = montonReservar(4000)
    hold reutiliza = d == b
    montonLiberar(a)
    montonLiberar(c)
    montonLiberar(d)
    hold e = montonReservar(60000)
    hold fusiona = e == a
    montonLiberar(e)
    kprint(cadena("montón: "))
    kprintHex(a)
    kprint(cadena(", en uso al final "))
    kprintEntero(montonEnUso())
    kprintByte(10)
    when reutiliza && fusiona && montonEnUso() == 0 {
        kprintln(cadena("hito 4 OK"))
    } otherwise {
        kprintln(cadena("hito 4 FALLÓ: el montón no reutiliza o no fusiona"))
    }
}

// Hito 5: CPUID, SSE y FXSAVE.
flow hito5() {
    hold base = cpuInforme()
    cpuActivarSse()
    hold mxcsr = cpuProbarFxsave()
    kprint(cadena("SSE activo, MXCSR = "))
    kprintHex(mxcsr)
    kprintByte(10)
    hold x = 1.5 * 2.0 + 0.25
    when base && x == 3.25 && (mxcsr & 0xFFFF) == 0x1F80 {
        kprintln(cadena("hito 5 OK"))
    } otherwise {
        kprintln(cadena("hito 5 FALLÓ"))
    }
}

// Hito 6: ACPI, HPET, LAPIC (temporizador periódico calibrado).
flow hito6() {
    when !acpiIniciar() {
        kprintln(cadena("hito 6 FALLÓ: sin tablas ACPI (MADT/IOAPIC)"))
        give
    }
    kprint(cadena("ACPI: LAPIC "))
    kprintHex(acpiLapicFisica())
    kprint(cadena(", IOAPIC "))
    kprintHex(acpiIoapicFisica())
    kprint(cadena(", HPET "))
    kprintHex(acpiHpetFisica())
    kprint(cadena(", CPU: "))
    kprintEntero(acpiCpus())
    kprintByte(10)
    hold fuente = relojIniciar()
    when fuente == RELOJ_NINGUNO {
        kprintln(cadena("hito 6 FALLÓ: sin HPET ni temporizador PM de ACPI"))
        give
    }
    lapicIniciar()
    lapicCalibrar()
    when fuente == RELOJ_HPET { kprint(cadena("HPET ")) } otherwise { kprint(cadena("temporizador PM ")) }
    kprintEntero(relojFrecuencia())
    kprint(cadena(" Hz; TSC "))
    kprintEntero(tscCiclosPorMs() / 1000)
    kprint(cadena(" MHz; LAPIC "))
    kprintEntero(lapicCuentasPorMs())
    kprintln(cadena(" cuentas/ms (divisor 16)"))
    temporizadorConfigurar(10)
    lapicTemporizadorPeriodico(10)
    sti()
    hold r0 = relojNanosegundos()
    temporizadorDormir(500)
    hold ms = (relojNanosegundos() - r0) / 1000000
    kprint(cadena("500 ms del temporizador = "))
    kprintEntero(ms)
    kprint(cadena(" ms del reloj de referencia ("))
    kprintEntero(temporizadorTics())
    kprintln(cadena(" tics)"))
    when ms >= 400 && ms <= 700 {
        kprintln(cadena("hito 6 OK"))
    } otherwise {
        kprintln(cadena("hito 6 FALLÓ: el temporizador no coincide con el HPET"))
    }
}

// Hito 7: teclado PS/2 latinoamericano por IOAPIC.
flow hito7() {
    tecladoIniciar()
    ioapicIniciar()
    ioapicDirigirIrq(1, VECTOR_TECLADO, lapicId())
    kprintln(cadena("hito 7: escriba una línea y pulse Intro"))
    hold linea = reservar(4096, 8)
    change n = 0
    during true {
        hlt()
        change cp = tecladoLeer()
        during cp >= 0 {
            when cp == TECLA_INTRO {
                kprintByte(10)
                kprint(cadena("teclado: "))
                each i among 0..n { kprintCaracter(leer64(linea + i * 8)) }
                kprintByte(10)
                n = 0
            } otherwise when cp == TECLA_BORRAR {
                when n > 0 {
                    n -= 1
                    kprintRetroceso()
                }
            } otherwise when n < 512 {
                escribir64(linea + n * 8, cp)
                n += 1
                kprintCaracter(cp)
            }
            cp = tecladoLeer()
        }
    }
}

// Hito 8: procesadores secundarios con INIT-SIPI-SIPI.
flow hito8() {
    hold esperados = acpiCpus() - 1
    hold despiertos = smpIniciar()
    kprint(cadena("SMP: "))
    kprintEntero(despiertos)
    kprint(cadena(" de "))
    kprintEntero(esperados)
    kprintln(cadena(" procesadores secundarios en línea"))
    when despiertos == esperados && esperados > 0 {
        kprintln(cadena("hito 8 OK"))
    } otherwise {
        kprintln(cadena("hito 8 FALLÓ"))
    }
}

// Hito 9: SGEMM con SSE empaquetado (MULPS/ADDPS, acumuladores en XMM).
flow hito9() {
    when sgemmBanco(256) {
        kprintln(cadena("hito 9 OK"))
    } otherwise {
        kprintln(cadena("hito 9 FALLÓ: resultado incorrecto"))
    }
}
