// ACPI mínimo: RSDP -> XSDT/RSDT -> MADT (APIC) y HPET.
//
// Las tablas están en memoria física; se mapean bajo demanda en el HHDM
// (pueden estar en regiones "reservadas" que el PML4 no incluye).

take nucleo.mem
take arranque.limine
take mem.fisica
take mem.paginacion

// Estado: +0 dirección física de la XSDT o RSDT, +8 1 si es XSDT,
// +16 LAPIC física, +24 IOAPIC física, +32 GSI base de la IOAPIC,
// +40 HPET física, +48 número de CPU (LAPIC habilitados),
// +56.. tabla de ISO: GSI de cada IRQ ISA 0..15 (16 palabras),
// +184.. banderas de cada ISO (16 palabras), +312.. ids LAPIC (64),
// +832 puerto del temporizador PM, +840 1 si ese contador es de 32 bits.
flow estado() => Int { give reservar(848, 8) }

expose flow acpiLapicFisica() => Int { give leer64(estado() + 16) }
expose flow acpiIoapicFisica() => Int { give leer64(estado() + 24) }
expose flow acpiIoapicBase() => Int { give leer64(estado() + 32) }
expose flow acpiHpetFisica() => Int { give leer64(estado() + 40) }
expose flow acpiCpus() => Int { give leer64(estado() + 48) }
expose flow acpiPuertoPm() => Int { give leer64(estado() + 832) }
expose flow acpiPm32Bits() => Bool { give leer64(estado() + 840) == 1 }
expose flow acpiIdLapic(i: Int) => Int { give leer64(estado() + 312 + i * 8) }

// GSI de la IRQ ISA `irq` y sus banderas MPS (polaridad / disparo).
expose flow acpiGsiDeIrq(irq: Int) => Int { give leer64(estado() + 56 + irq * 8) }
expose flow acpiBanderasDeIrq(irq: Int) => Int { give leer64(estado() + 184 + irq * 8) }

// Mapea `largo` bytes desde la física `fisica` y devuelve su virtual.
flow mapear(fisica: Int, largo: Int) => Int {
    change p = fisica & (~0xFFF)
    during p < fisica + largo {
        pagMapear4k(memVirtual(p), p, PAG_ESCRITURA)
        p += MARCO
    }
    give memVirtual(fisica)
}

flow tabla(fisica: Int) => Int {
    hold cabecera = mapear(fisica, 36)
    give mapear(fisica, leer32(cabecera + 4))
}

flow firmaEs(t: Int, a: Int, b: Int, c: Int, d: Int) => Bool {
    give leer8(t) == a && leer8(t + 1) == b && leer8(t + 2) == c && leer8(t + 3) == d
}

// Física de la primera tabla con esa firma de 4 letras, o 0.
flow buscar(a: Int, b: Int, c: Int, d: Int) => Int {
    hold e = estado()
    hold raiz = tabla(leer64(e))
    hold ancho = 4 + 4 * leer64(e + 8)
    hold cuantas = (leer32(raiz + 4) - 36) / ancho
    each i among 0..cuantas {
        change f = leer32(raiz + 36 + i * ancho)
        when ancho == 8 { f = leer64(raiz + 36 + i * ancho) }
        when firmaEs(tabla(f), a, b, c, d) { give f }
    }
    give 0
}

flow leerMadt(madt: Int) {
    hold e = estado()
    hold t = tabla(madt)
    escribir64(e + 16, leer32(t + 36))
    hold fin = t + leer32(t + 4)
    change p = t + 44
    during p + 2 <= fin && leer8(p + 1) >= 2 {
        hold tipo = leer8(p)
        when tipo == 0 && leer32(p + 4) & 1 == 1 && leer64(e + 48) < 64 {
            // Procesador local habilitado.
            hold n = leer64(e + 48)
            escribir64(e + 312 + n * 8, leer8(p + 3))
            escribir64(e + 48, n + 1)
        }
        when tipo == 1 && leer64(e + 24) == 0 {
            escribir64(e + 24, leer32(p + 4))
            escribir64(e + 32, leer32(p + 8))
        }
        when tipo == 2 && leer8(p + 3) < 16 {
            // Interrupt Source Override: IRQ ISA -> GSI.
            hold irq = leer8(p + 3)
            escribir64(e + 56 + irq * 8, leer32(p + 4))
            escribir64(e + 184 + irq * 8, leer16(p + 8))
        }
        when tipo == 5 { escribir64(e + 16, leer64(p + 4)) }
        p += leer8(p + 1)
    }
}

// false si no hay RSDP, MADT o IOAPIC.
expose flow acpiIniciar() => Bool {
    hold e = estado()
    each irq among 0..16 {
        escribir64(e + 56 + irq * 8, irq)
        escribir64(e + 184 + irq * 8, 0)
    }
    change rsdp = arranqueRsdp()
    when rsdp == 0 { give false }
    // Con la revisión base 3 es física; con versiones antiguas, virtual.
    when rsdp > 0 { rsdp = mapear(rsdp, 36) }
    when leer8(rsdp + 15) >= 2 && leer64(rsdp + 24) != 0 {
        escribir64(e, leer64(rsdp + 24))
        escribir64(e + 8, 1)
    } otherwise {
        escribir64(e, leer32(rsdp + 16))
        escribir64(e + 8, 0)
    }
    hold madt = buscar(65, 80, 73, 67)    // "APIC"
    when madt == 0 { give false }
    leerMadt(madt)
    hold hpet = buscar(72, 80, 69, 84)    // "HPET"
    when hpet != 0 { escribir64(e + 40, leer64(tabla(hpet) + 44)) }
    // FADT: PM_TMR_BLK (+76, puerto de E/S) y TMR_VAL_EXT (bit 8 de +112).
    hold fadt = buscar(70, 65, 67, 80)    // "FACP"
    when fadt != 0 {
        hold t = tabla(fadt)
        escribir64(e + 832, leer32(t + 76))
        escribir64(e + 840, (leer32(t + 112) >> 8) & 1)
    }
    give leer64(e + 24) != 0
}
