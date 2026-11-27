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
take dispositivos.pci
take dispositivos.ahci
take almacenamiento.disco
take lib.crc32
take almacenamiento.fat32
take almacenamiento.checkpoint
take lib.aleatorio
take lib.tensor
take lib.vexp
take bench.gradientes
take bench.aprender
take enca.exp009
take enca.exp010
take enca.interactivo
take enca.muestreo
take enca.hito18
take enca.aprender
take enca.hito21
take tiempo.reloj

flow kmain() {
    // Antes que nada: copia propia de las respuestas de Limine.
    arranqueCopiar()
    consolaIniciar()
    kprintln(cadena("ELE kernel OK"))
    // Línea de órdenes de Limine (opciones de arranque, p. ej. enca=nuevo).
    kprint(cadena("línea de órdenes: "))
    when leer64(arranqueLinea()) == 0 {
        kprintln(cadena("(vacía)"))
    } otherwise {
        kprintln(arranqueLinea())
    }

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
    hito12()
    hito13()
    hito14()
    hito15()
    hito16()
    hito20()
    hito17()
    hito18()
    hito21()
    hitoCrc32c()
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
    hold mib = 1048576
    kprint(cadena("RAM: "))
    kprintEntero(memFisicaTotalBytes() / mib)
    kprint(cadena(" MiB (usable "))
    kprintEntero(memBytesDeTipo(MEMORIA_USABLE) / mib)
    kprint(cadena(", del cargador "))
    kprintEntero(memBytesDeTipo(MEMORIA_CARGADOR_RECUPERABLE) / mib)
    kprint(cadena(", kernel "))
    kprintEntero(memBytesDeTipo(MEMORIA_KERNEL) / 1024)
    kprintln(cadena(" KiB)"))
    kprint(cadena("  no RAM: reservada "))
    kprintEntero(memBytesDeTipo(MEMORIA_RESERVADA) / mib)
    kprint(cadena(" MiB, ACPI "))
    kprintEntero((memBytesDeTipo(MEMORIA_ACPI_RECUPERABLE) + memBytesDeTipo(MEMORIA_ACPI_NVS)) / 1024)
    kprint(cadena(" KiB, framebuffer "))
    kprintEntero(memBytesDeTipo(MEMORIA_FRAMEBUFFER) / 1024)
    kprint(cadena(" KiB, defectuosa "))
    kprintEntero(memBytesDeTipo(MEMORIA_DEFECTUOSA) / 1024)
    kprintln(cadena(" KiB"))
    when !pagIniciar() {
        kprintln(cadena("hito 4 FALLÓ: no se pudo construir el PML4"))
        give
    }
    kprint(cadena("paginación propia activa, CR3 = "))
    kprintHex(leerCr3())
    kprintByte(10)
    hold libres_antes = memFisicaLibres() * MARCO
    hold recuperados = memFisicaRecuperarCargador(leerRsp())
    kprint(cadena("libres: "))
    kprintEntero(libres_antes / mib)
    kprint(cadena(" MiB; tras recuperar la memoria del cargador ("))
    kprintEntero(recuperados / mib)
    kprint(cadena(" MiB): "))
    kprintEntero(memFisicaLibres() * MARCO / mib)
    kprintln(cadena(" MiB"))

    montonIniciar()
    hold a = montonReservar(100)
    when a == 0 {
        kprint(cadena("hito 4 FALLÓ: el montón no pudo crecer (motivo "))
        kprintEntero(montonUltimoFallo())
        kprint(cadena(", marco "))
        kprintHex(montonMarcoDelFallo())
        kprint(cadena(", libres "))
        kprintEntero(memFisicaLibres())
        kprintln(cadena(" marcos)"))
        memImprimirMapa()
        give
    }
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
    // Con el modelo de ENCA entrenado o cargado (hito 17) el bucle es el modo
    // interactivo: se completa en pantalla el prefijo tecleado. Sin él, es
    // el eco de siempre.
    hold modelo = encaModelo()
    when modelo != 0 {
        mzDefecto()
        kprintln(cadena("hito 7: ENCA interactiva, escriba un prefijo (p. ej. flow main) y pulse Intro; :ayuda lista los comandos"))
        kprint(cadena("ENCA> "))
    } otherwise {
        kprintln(cadena("hito 7: escriba una línea y pulse Intro"))
    }
    hold linea = reservar(4096, 8)
    hold bytes = reservar(2304, 8)
    change n = 0
    during true {
        hlt()
        change cp = tecladoLeer()
        during cp >= 0 {
            when cp == TECLA_INTRO && modelo != 0 && n > 0 && leer64(linea) == 58 {
                // Línea que empieza por ':': comando de configuración.
                kprintByte(10)
                when !aprComando(linea, n) { mzComando(linea, n) }
                kprint(cadena("ENCA> "))
                n = 0
            } otherwise when cp == TECLA_INTRO && modelo != 0 {
                // El prefijo pasa a bytes UTF-8, como estaría en un archivo.
                change nb = 0
                each i among 0..n { nb += utf8Codificar(leer64(linea + i * 8), bytes + nb) }
                when aprendiendo() && nb > 0 { aprTeclear(modelo, bytes, nb, linea, n) }
                encaCompletar(modelo, bytes, nb)
                kprint(cadena("ENCA> "))
                n = 0
            } otherwise when cp == TECLA_INTRO {
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
    // Hito 11 (sustituye al banco del hito 9): SGEMM general en todos los
    // núcleos, variantes del micronúcleo y tabla de rendimiento.
    when sgemmHito11() {
        kprintln(cadena("hito 11 OK"))
    } otherwise {
        kprintln(cadena("hito 11 FALLÓ"))
    }
}

// Hito 12: PCI Express por ECAM.
flow hito12() {
    when !pciEnumerar() {
        kprintln(cadena("hito 12 FALLÓ: ACPI no tiene tabla MCFG"))
        give
    }
    kprint(cadena("PCI: ECAM en "))
    kprintHex(acpiEcamFisica())
    kprint(cadena(", buses "))
    kprintEntero(acpiPrimerBus())
    kprint(cadena("-"))
    kprintEntero(acpiUltimoBus())
    kprint(cadena(", "))
    kprintEntero(pciCantidad())
    kprintln(cadena(" funciones:"))
    pciImprimir()
    hold i = pciDisco()
    when i < 0 {
        kprintln(cadena("disco: no se encontró controlador AHCI ni NVMe"))
        kprintln(cadena("hito 12 FALLÓ"))
        give
    }
    hold ent = pciEntrada(i)
    hold tipo = pciTipoDisco(leer64(ent + 16))
    kprint(cadena("disco: "))
    when tipo == DISCO_AHCI { kprint(cadena("AHCI")) }
    when tipo == DISCO_NVME { kprint(cadena("NVMe")) }
    when tipo == DISCO_RAID { kprint(cadena("RAID")) }
    when tipo == DISCO_IDE { kprint(cadena("IDE heredado")) }
    kprint(cadena(" en el bdf "))
    kprintHex(leer64(ent))
    when pciCapacidad(leer64(ent), 0x05) != 0 { kprint(cadena(", con MSI")) }
    kprintByte(10)
    when tipo == DISCO_RAID || tipo == DISCO_IDE {
        kprintln(cadena("*** DETENIDO: el disco no está en modo AHCI/NVMe (¿RAID / Intel RST?)."))
        kprintln(cadena("*** Cambiar a AHCI en el firmware antes del hito 13."))
        kprintln(cadena("hito 12 OK (sin driver de disco posible)"))
        give
    }
    pciHabilitarDma(leer64(ent))
    kprintln(cadena("bus mastering activado en el controlador de disco"))
    kprintln(cadena("hito 12 OK"))
}

// Generador xorshift64 para el patrón de prueba del disco.
flow siguienteAleatorio(x: Int) => Int {
    change y = x ^ (x << 13)
    y = y ^ (y >> 7)
    give y ^ (y << 17)
}

// Hito 13: AHCI, GPT, lectura secuencial y escritura protegida.
flow hito13() {
    hold discos = ahciIniciar()
    kprint(cadena("AHCI versión "))
    kprintHex(ahciVersion())
    kprint(cadena(": "))
    kprintEntero(discos)
    kprintln(cadena(" disco(s)"))
    when discos == 0 {
        kprintln(cadena("hito 13 FALLÓ: ningún disco SATA"))
        give
    }
    change elegido = -1
    each d among 0..discos {
        kprint(cadena("disco "))
        kprintEntero(d)
        kprint(cadena(" (puerto "))
        kprintEntero(ahciPuerto(d))
        kprint(cadena("): "))
        kprintEntero(ahciSectores(d) / 2048)
        kprintln(cadena(" MiB"))
        when discoAbrir(d, true) {
            when discoHayPermitida() && elegido < 0 { elegido = d }
        } otherwise {
            kprintln(cadena("  sin GPT válida"))
        }
    }

    // Lectura secuencial: 64 MiB (o el disco entero si es menor) desde el
    // LBA 2048 del disco 0, de 256 KiB en 256 KiB.
    change disco_medida = elegido
    when disco_medida < 0 { disco_medida = 0 }
    hold reabierto = discoAbrir(disco_medida, false)
    hold buf = montonReservar(262144)
    change sectores = 131072
    when ahciSectores(discoActual()) - 2048 < sectores { sectores = ahciSectores(discoActual()) - 2048 }
    hold t0 = relojNanosegundos()
    change leido = 0
    change lectura_bien = true
    during leido + 512 <= sectores && lectura_bien {
        lectura_bien = discoLeer(2048 + leido, 512, buf)
        leido += 512
    }
    hold ns = relojNanosegundos() - t0
    kprint(cadena("lectura secuencial: "))
    kprintEntero(leido / 2048)
    kprint(cadena(" MiB en "))
    kprintEntero(ns / 1000000)
    kprint(cadena(" ms = "))
    when ns > 0 { kprintEntero(leido * 512 * 1000 / ns) }
    kprintln(cadena(" MB/s"))

    when elegido < 0 {
        kprintln(cadena("sin partición marcada para ELE: el disco queda en SOLO LECTURA"))
        kprintln(cadena("hito 13 incompleto: crear una partición FAT32 con etiqueta ELEDATOS (ver kernel/README.md)"))
        give
    }
    kprint(cadena("partición ELE: LBA "))
    kprintEntero(discoPermitidoPrimero())
    kprint(cadena(" - "))
    kprintEntero(discoPermitidoUltimo())
    kprintByte(10)
    // Comprobación de la regla (sin escribir): fuera se rechaza.
    when discoEscrituraPermitida(0, 1) || discoEscrituraPermitida(discoPermitidoPrimero() - 1, 2) {
        kprintln(cadena("hito 13 FALLÓ: la regla de escritura deja pasar el LBA 0"))
        give
    }
    kprintln(cadena("regla: escritura fuera de la partición rechazada (LBA 0 y frontera)"))
    hold habilitada = discoHabilitarEscritura()

    // Prueba no destructiva: los 64 últimos sectores de la partición se
    // guardan, se escribe un patrón, se verifica con CRC32 y se restauran.
    hold n = 64
    hold lba = discoPermitidoUltimo() - n + 1
    hold bytes = n * 512
    hold original = montonReservar(bytes)
    hold patron = montonReservar(bytes)
    hold lectura = montonReservar(bytes)
    change bien = discoLeer(lba, n, original)
    hold crc_original = crc32(original, bytes)
    change x = 0x9E3779B97F4A7C15
    change i = 0
    during i < bytes {
        x = siguienteAleatorio(x)
        escribir64(patron + i, x)
        i += 8
    }
    hold crc_patron = crc32(patron, bytes)
    bien = bien && discoEscribir(lba, n, patron) && discoLeer(lba, n, lectura)
    hold crc_leido = crc32(lectura, bytes)
    bien = bien && discoEscribir(lba, n, original) && discoLeer(lba, n, lectura)
    hold crc_restaurado = crc32(lectura, bytes)
    kprint(cadena("escritura de prueba (LBA "))
    kprintEntero(lba)
    kprint(cadena(", 32 KiB): patrón CRC32 "))
    kprintHex(crc_patron)
    kprint(cadena(", leído "))
    kprintHex(crc_leido)
    kprint(cadena("; original "))
    kprintHex(crc_original)
    kprint(cadena(", restaurado "))
    kprintHex(crc_restaurado)
    kprintByte(10)
    when bien && crc_patron == crc_leido && crc_original == crc_restaurado {
        kprintln(cadena("hito 13 OK"))
    } otherwise {
        kprintln(cadena("hito 13 FALLÓ"))
    }
}

// Datos de prueba de un checkpoint: 1 MiB que depende solo del paso.
flow datosDePaso(paso: Int, dir: Int, bytes: Int) {
    change x = 0x9E3779B97F4A7C15 ^ (paso * 0x100000001B3)
    when x == 0 { x = 1 }
    change i = 0
    during i < bytes {
        x = siguienteAleatorio(x)
        escribir64(dir + i, x)
        i += 8
    }
}

// Hito 14: FAT32 y checkpoints A/B.
flow hito14() {
    when !discoHayPermitida() {
        kprintln(cadena("hito 14 pendiente: no hay partición ELEDATOS en el disco"))
        give
    }
    when !fatMontar() {
        kprintln(cadena("hito 14 FALLÓ: la partición permitida no es FAT32"))
        give
    }
    kprint(cadena("FAT32 montada: "))
    kprintEntero(fatBytesPorCluster())
    kprintln(cadena(" bytes por cluster"))
    change bien = true

    // 1. Archivo de texto creado en Windows.
    when fatAbrir(cadena("texto.txt")) {
        hold tam = fatTamanoArchivo()
        hold buf = montonReservar(tam + 65536)
        hold t0 = relojNanosegundos()
        hold leidos = fatLeer(0, tam, buf)
        hold ns = relojNanosegundos() - t0
        kprint(cadena("texto.txt: "))
        kprintEntero(leidos)
        kprint(cadena(" bytes en "))
        kprintEntero(ns / 1000000)
        kprint(cadena(" ms, CRC32 "))
        kprintHex(crc32(buf, leidos))
        kprintByte(10)
        kprint(cadena("  primera línea: "))
        change i = 0
        during i < leidos && i < 100 && leer8(buf + i) != 10 {
            kprintByte(leer8(buf + i))
            i += 1
        }
        kprintByte(10)
        when leidos != tam { bien = false }
        montonLiberar(buf)
    } otherwise {
        kprintln(cadena("texto.txt: no está en la partición (cópielo desde Windows)"))
    }

    // 2. Escritura simple de un archivo nuevo, leído de vuelta.
    hold contenido = cadena("Archivo escrito por el kernel ELE: hola, ñandú.\n")
    hold n = leer64(contenido)
    hold salida = montonReservar(512)
    each k among 0..64 { escribir64(salida + k * 8, 0) }
    each k among 0..n { escribir8(salida + k, leer8(contenido + 8 + k)) }
    change escrito = fatCrear(cadena("SALIDA  TXT"), cadena("SALIDA.TXT"), n)
    escrito = escrito && fatEscribir(0, 512, salida) && discoVaciar()
    hold relectura = montonReservar(fatBytesPorCluster())
    escrito = escrito && fatAbrir(cadena("salida.txt")) && fatLeer(0, n, relectura) == n
    escrito = escrito && crc32(relectura, n) == crc32(salida, n)
    when escrito {
        kprintln(cadena("SALIDA.TXT escrito y leído de vuelta: idéntico"))
    } otherwise {
        kprintln(cadena("SALIDA.TXT: FALLÓ"))
        bien = false
    }

    // 3. Checkpoints A/B con corte simulado.
    hold capacidad = 1048576
    hold datos = montonReservar(capacidad)
    hold esperado = montonReservar(capacidad)
    when !ckptPreparar(CKPT_PRUEBA, capacidad) {
        kprintln(cadena("checkpoints: no se pudieron crear las ranuras"))
        kprintln(cadena("hito 14 FALLÓ"))
        give
    }
    hold paso = ckptCargar(CKPT_PRUEBA, datos)
    change base = 0
    when paso < 0 {
        kprintln(cadena("checkpoint: ninguno válido (primer arranque)"))
    } otherwise {
        datosDePaso(paso, esperado, capacidad)
        kprint(cadena("checkpoint recuperado: paso "))
        kprintEntero(paso)
        kprint(cadena(" de la ranura "))
        when ckptRanuraCargada(CKPT_PRUEBA) == 0 { kprint(cadena("A")) } otherwise { kprint(cadena("B")) }
        when crc32(datos, capacidad) == crc32(esperado, capacidad) {
            kprintln(cadena(", datos verificados"))
        } otherwise {
            kprintln(cadena(", DATOS INCORRECTOS"))
            bien = false
        }
        base = paso
    }
    datosDePaso(base + 1, datos, capacidad)
    hold guardado = ckptGuardar(CKPT_PRUEBA, base + 1, datos, capacidad, false)
    datosDePaso(base + 2, datos, capacidad)
    hold cortado = ckptGuardar(CKPT_PRUEBA, base + 2, datos, capacidad, true)
    kprint(cadena("guardado el paso "))
    kprintEntero(base + 1)
    kprint(cadena("; corte simulado a mitad del paso "))
    kprintEntero(base + 2)
    kprintByte(10)
    hold recuperado = ckptCargar(CKPT_PRUEBA, datos)
    datosDePaso(base + 1, esperado, capacidad)
    kprint(cadena("recarga inmediata: paso "))
    kprintEntero(recuperado)
    kprintln(cadena(" (debe ser el anterior al corte; al reiniciar debe salir el mismo)"))
    when !guardado || !cortado || recuperado != base + 1 || crc32(datos, capacidad) != crc32(esperado, capacidad) { bien = false }
    when bien { kprintln(cadena("hito 14 OK")) } otherwise { kprintln(cadena("hito 14 FALLÓ")) }
}

// Hito 15: tensores, aleatorio determinista, exp/tanh SSE y gradientes.
flow hito15() {
    hold g = reservar(16, 8)
    pcgSembrar(g, 42, 54)
    kprint(cadena("PCG32 (semilla 42, secuencia 54): "))
    each i among 0..4 {
        kprintHex(pcgSiguiente(g))
        kprintByte(32)
    }
    kprintByte(10)
    hold t = tNuevo(64, 256, F32, true)
    kprint(cadena("tensor 64x256 f32: datos en "))
    kprintHex(tDatos(t))
    kprint(cadena(" (alineado a 64: "))
    when tDatos(t) & 63 == 0 { kprint(cadena("sí")) } otherwise { kprint(cadena("NO")) }
    kprint(cadena("), arena usada "))
    kprintEntero(arenaUsada() / 1024)
    kprintln(cadena(" KiB"))
    hold vec = vexpMedir(2097152)
    hold grad = gradientesVerificar()
    when vec && grad && tDatos(t) & 63 == 0 {
        kprintln(cadena("hito 15 OK"))
    } otherwise {
        kprintln(cadena("hito 15 FALLÓ"))
    }
}

// CRC-32C: la instrucción CRC32 (SSE4.2) frente a la tabla de referencia.
flow hitoCrc32c() {
    hold n = 1048576 * 64
    hold b = montonReservar(n + 64)
    when b == 0 {
        kprintln(cadena("hito crc32c FALLÓ: sin memoria"))
        give
    }
    // Datos pseudoaleatorios y valor de comprobación estándar.
    hold g = reservar(16, 8)
    pcgSembrar(g, 7, 11)
    each i among 0..(n / 4) { escribir32(b + i * 4, pcgSiguiente(g)) }
    hold check = montonReservar(16)
    hold texto = cadena("123456789")
    each i among 0..9 { escribir8(check + i, leer8(texto + 8 + i)) }
    hold v = crc32cSse(check, 9)
    kprint(cadena("crc32c(123456789) = "))
    kprintHex(v)
    kprintByte(10)
    change bien = v == 0xE3069283 && crc32cSoft(check, 9) == 0xE3069283
    // Tamaños y alineaciones: ambas implementaciones deben coincidir.
    each desp among 0..9 {
        each k among 0..40 {
            hold largo = k * 7 + desp
            when crc32cSse(b + desp, largo) != crc32cSoft(b + desp, largo) { bien = false }
        }
    }
    hold t0 = relojNanosegundos()
    hold cs = crc32cSoft(b, n)
    hold t1 = relojNanosegundos()
    hold ce = crc32cSse(b, n)
    hold t2 = relojNanosegundos()
    when cs != ce { bien = false }
    hold msSoft = (t1 - t0) / 1000000
    hold msSse = (t2 - t1) / 1000000
    kprint(cadena("crc32c 64 MiB: software "))
    kprintEntero(msSoft)
    kprint(cadena(" ms ("))
    when msSoft > 0 { kprintEntero(64 * 1000 / msSoft) }
    kprint(cadena(" MB/s), SSE4.2 "))
    kprintEntero(msSse)
    kprint(cadena(" ms ("))
    when msSse > 0 { kprintEntero(64 * 1000 / msSse) }
    kprintln(cadena(" MB/s)"))
    montonLiberar(check)
    montonLiberar(b)
    when bien { kprintln(cadena("hito crc32c OK")) } otherwise { kprintln(cadena("hito crc32c FALLÓ")) }
}

// Línea base opcional (PAUSADA, no se llama): AdamW, XOR/círculos y bigramas.
flow lineaBaseAdamW() {
    when aprenderTodo() {
        kprintln(cadena("hito 16 OK"))
    } otherwise {
        kprintln(cadena("hito 16 FALLÓ"))
    }
}

// Hito 17: ENCA en modo rápido (f32 + SSE + 2 núcleos) frente al exacto.
flow hito17() {
    hold r = encaHito17()
    when r == 1 {
        kprintln(cadena("hito 17 OK"))
    } otherwise when r == 2 {
        kprintln(cadena("hito 17 omitido (sin corpus)"))
    } otherwise {
        kprintln(cadena("hito 17 FALLÓ"))
    }
}

// Hito 18: generación sin bucles (muestreo) frente al voraz.
flow hito18() {
    hold r = encaHito18()
    when r == 1 {
        kprintln(cadena("hito 18 OK"))
    } otherwise when r == 2 {
        kprintln(cadena("hito 18 omitido (sin modelo de ENCA)"))
    } otherwise {
        kprintln(cadena("hito 18 FALLÓ"))
    }
}

// Hito 21: ENCA aprende de lo que escribe el usuario (enca/aprender.l).
// La prueba de aceptación solo corre con la opción de arranque enca=prueba21;
// sin ella se mide F con el modelo cargado (lo aprendido sobrevive al reinicio).
flow hito21() {
    when encaModelo() == 0 {
        kprintln(cadena("hito 21 omitido (sin modelo de ENCA)"))
        give
    }
    aprInicializar()
    when arranqueOpcionEs(cadena("enca"), cadena("estudio21")) {
        encaEstudio21()
        give
    }
    when !arranqueOpcionEs(cadena("enca"), cadena("prueba21")) {
        kprintln(cadena("hito 21: prueba con enca=prueba21"))
        encaMedirF()
        give
    }
    hold r = encaHito21()
    when r == 1 {
        kprintln(cadena("hito 21 OK"))
    } otherwise when r == 2 {
        kprintln(cadena("hito 21 omitido (sin ranuras de ENCA)"))
    }
}

// Hito 20: exp010 (C5 + evaluación precuencial) reproducido en modo exacto.
// Solo con la opción de arranque enca=exp010 (cuesta ~2 min más). Va tras el
// hito 16 porque reutiliza el corpus ya verificado.
flow hito20() {
    when !arranqueOpcionEs(cadena("enca"), cadena("exp010")) {
        kprintln(cadena("hito 20: se ejecuta con la opción de arranque enca=exp010"))
        give
    }
    hold r = encaExp010()
    when r == 1 {
        kprintln(cadena("hito 20 OK"))
    } otherwise when r == 2 {
        kprintln(cadena("hito 20 omitido (sin corpus)"))
    } otherwise {
        kprintln(cadena("hito 20 FALLÓ"))
    }
}

// Hito 16: ENCA (exp009, configuración C5) reproduce exactamente los números
// de Windows (ver enca/exp009.l). Necesita enca/ en la partición ELEDATOS.
flow hito16() {
    hold r = encaEjecutar(0)
    when r == 1 {
        kprintln(cadena("hito 16 OK"))
    } otherwise when r == 2 {
        kprintln(cadena("hito 16 omitido (sin corpus)"))
    } otherwise {
        kprintln(cadena("hito 16 FALLÓ"))
    }
}
