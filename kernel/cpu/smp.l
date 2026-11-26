// Arranque de los procesadores secundarios (AP) con INIT-SIPI-SIPI, sin
// la ayuda SMP de Limine.
//
// El AP despierta en modo real en `base` (un marco por debajo de 1 MiB,
// vector SIPI = base / 4096). El trampolín, escrito aquí byte a byte, pasa
// a modo protegido con una GDT temporal, activa PAE + LME + paginación con
// el PML4 del kernel (que mapea `base` 1:1) y salta en 64 bits al stub de la
// interrupción 240: así entra en `kinterrupcion`, que llama a smpEntradaAp
// en la pila propia del AP. Los AP se arrancan de uno en uno.
//
// Desplazamientos dentro del trampolín:
//   0x000 código de 16 bits     0x080 código de 32 bits
//   0x100 código de 64 bits     0x180 GDT temporal (4 entradas)
//   0x1A0 puntero de la GDT     0x1B0 CR3   0x1B8 pila   0x1C0 destino

take nucleo.cpu
take nucleo.mem
take mem.fisica
take mem.paginacion
take mem.monton
take cpu.gdt
take cpu.idt
take cpu.caracteristicas
take dispositivos.acpi
take dispositivos.apic
take tiempo.reloj
take cpu.buzon
take cpu.trabajos

expose fixed VECTOR_ENTRADA_AP = 240
fixed TAMANO_PILA_AP = 16384

// Estado: +0 base física del trampolín, +8 cursor de escritura,
// +16 AP en línea, +24 último id LAPIC que respondió.
flow estado() => Int { give reservar(32, 8) }

expose flow smpEnLinea() => Int { give leer64(estado() + 16) }

flow poner(b: Int) {
    hold e = estado()
    escribir8(memVirtual(leer64(e) + leer64(e + 8)), b)
    escribir64(e + 8, leer64(e + 8) + 1)
}

flow poner32(v: Int) {
    each i among 0..4 { poner((v >> (8 * i)) & 0xFF) }
}

flow irA(desplazamiento: Int) {
    escribir64(estado() + 8, desplazamiento)
}

flow escribirTrampolin(base: Int) {
    // 16 bits: CLI; CLD; MOV AX,CS; MOV DS,AX; LGDT [0x1A0];
    // MOV EAX,CR0; OR AL,1; MOV CR0,EAX; JMP DWORD 0x08:base+0x80.
    irA(0)
    poner(0xFA)
    poner(0xFC)
    poner(0x8C)
    poner(0xC8)
    poner(0x8E)
    poner(0xD8)
    poner(0x0F)
    poner(0x01)
    poner(0x16)
    poner(0xA0)
    poner(0x01)
    poner(0x0F)
    poner(0x20)
    poner(0xC0)
    poner(0x0C)
    poner(0x01)
    poner(0x0F)
    poner(0x22)
    poner(0xC0)
    poner(0x66)
    poner(0xEA)
    poner32(base + 0x80)
    poner(0x08)
    poner(0x00)

    // 32 bits: segmentos de datos 0x10; CR4.PAE; CR3; EFER.LME;
    // CR0.PG|PE; JMP 0x18:base+0x100.
    irA(0x80)
    poner(0x66)
    poner(0xB8)
    poner(0x10)
    poner(0x00)
    poner(0x8E)
    poner(0xD8)
    poner(0x8E)
    poner(0xC0)
    poner(0x8E)
    poner(0xD0)
    poner(0x0F)
    poner(0x20)
    poner(0xE0)
    poner(0x83)
    poner(0xC8)
    poner(0x20)
    poner(0x0F)
    poner(0x22)
    poner(0xE0)
    poner(0xA1)
    poner32(base + 0x1B0)
    poner(0x0F)
    poner(0x22)
    poner(0xD8)
    poner(0xB9)
    poner32(0xC0000080)
    poner(0x0F)
    poner(0x32)
    poner(0x0D)
    poner32(0x100)
    poner(0x0F)
    poner(0x30)
    poner(0x0F)
    poner(0x20)
    poner(0xC0)
    poner(0x0D)
    poner32(0x80000001)
    poner(0x0F)
    poner(0x22)
    poner(0xC0)
    poner(0xEA)
    poner32(base + 0x100)
    poner(0x18)
    poner(0x00)

    // 64 bits: MOV RSP,[base+0x1B8]; MOV RAX,[base+0x1C0]; JMP RAX.
    irA(0x100)
    poner(0x48)
    poner(0x8B)
    poner(0x24)
    poner(0x25)
    poner32(base + 0x1B8)
    poner(0x48)
    poner(0x8B)
    poner(0x04)
    poner(0x25)
    poner32(base + 0x1C0)
    poner(0xFF)
    poner(0xE0)

    // GDT temporal: nulo, código 32, datos, código 64.
    hold v = memVirtual(base)
    escribir64(v + 0x180, 0)
    escribir64(v + 0x188, 0x00CF9A000000FFFF)
    escribir64(v + 0x190, 0x00CF92000000FFFF)
    escribir64(v + 0x198, 0x00AF9A000000FFFF)
    escribir16(v + 0x1A0, 31)
    escribir32(v + 0x1A2, base + 0x180)
    escribir64(v + 0x1B0, pagPml4())
    escribir64(v + 0x1C0, stubInterrupcion(VECTOR_ENTRADA_AP))
}

// Llamada desde kinterrupcion (vector 240) en la pila del AP: tablas del
// kernel, SSE y LAPIC; luego avisa al BSP y atiende su buzón para siempre
// (cpu/buzon.l, cpu/trabajos.l), con interrupciones desactivadas.
expose flow smpEntradaAp() {
    gdtCargarEnAp()
    idtCargarEnAp()
    cpuActivarSse()
    lapicIniciar()
    hold e = estado()
    escribir64(e + 24, lapicId())
    hold indice = leer64(e + 16) + 1
    escribir64(e + 16, indice)
    during true {
        hold b = buzonEsperarTrabajo(indice)
        trabajoEjecutar(leer64(b + 16), leer64(b + 24), indice)
        buzonTerminar(indice)
    }
}

// Despierta todos los AP que describe la MADT. Devuelve cuántos
// respondieron.
expose flow smpIniciar() => Int {
    hold e = estado()
    escribir64(e + 16, 0)
    hold base = memFisicaReservarBajo()
    when base == 0 { give 0 }
    escribir64(e, base)
    // El trampolín cambia a paginación en su propia dirección: 1:1.
    pagMapear4k(base, base, PAG_ESCRITURA)
    escribirTrampolin(base)
    hold propio = lapicId()
    hold v = memVirtual(base)
    each i among 0..acpiCpus() {
        hold id = acpiIdLapic(i)
        when id != propio {
            hold pila = montonReservar(TAMANO_PILA_AP)
            escribir64(v + 0x1B8, pila + TAMANO_PILA_AP)
            hold antes = leer64(e + 16)
            lapicEnviarIpi(id, 0x4500)
            relojEsperar(10000)
            lapicEnviarIpi(id, 0x4600 | (base >> 12))
            relojEsperar(200)
            when leer64(e + 16) == antes {
                lapicEnviarIpi(id, 0x4600 | (base >> 12))
            }
            change espera = 0
            during leer64(e + 16) == antes && espera < 1000 {
                relojEsperar(100)
                espera += 1
            }
        }
    }
    buzonFijarNucleos(leer64(e + 16) + 1)
    give leer64(e + 16)
}
