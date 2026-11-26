// LAPIC (temporizador e interrupciones locales) e IOAPIC (IRQ externas).

take nucleo.cpu
take nucleo.mem
take mem.paginacion
take dispositivos.acpi
take tiempo.hpet

expose fixed VECTOR_TEMPORIZADOR = 64
expose fixed VECTOR_TECLADO = 65
expose fixed VECTOR_ESPURIO = 255

fixed LAPIC_ID = 0x20
fixed LAPIC_EOI = 0xB0
fixed LAPIC_ESPURIO = 0xF0
fixed LAPIC_ICR_BAJO = 0x300
fixed LAPIC_ICR_ALTO = 0x310
fixed LAPIC_LVT_TEMPORIZADOR = 0x320
fixed LAPIC_CUENTA_INICIAL = 0x380
fixed LAPIC_CUENTA_ACTUAL = 0x390
fixed LAPIC_DIVISOR = 0x3E0
fixed MSR_APIC_BASE = 0x1B

// Estado: +0 LAPIC virtual, +8 IOAPIC virtual, +16 cuentas del
// temporizador por milisegundo, +24 ciclos de TSC por milisegundo.
flow estado() => Int { give reservar(32, 8) }

flow lapic() => Int { give leer64(estado()) }

expose flow lapicLeer(registro: Int) => Int { give leer32(lapic() + registro) }
expose flow lapicEscribir(registro: Int, valor: Int) { escribir32(lapic() + registro, valor) }
expose flow lapicId() => Int { give lapicLeer(LAPIC_ID) >> 24 }
expose flow lapicFin() { lapicEscribir(LAPIC_EOI, 0) }
expose flow lapicCuentasPorMs() => Int { give leer64(estado() + 16) }
expose flow tscCiclosPorMs() => Int { give leer64(estado() + 24) }

// Orden entre procesadores: ICR alto = destino, ICR bajo = orden; espera a
// que se entregue (bit 12).
expose flow lapicEnviarIpi(destino: Int, orden: Int) {
    lapicEscribir(LAPIC_ICR_ALTO, destino << 24)
    lapicEscribir(LAPIC_ICR_BAJO, orden)
    during lapicLeer(LAPIC_ICR_BAJO) & 0x1000 != 0 { pause() }
}

expose flow lapicIniciar() {
    hold base = rdmsr(MSR_APIC_BASE)
    // Habilitar el APIC global (bit 11).
    wrmsr(MSR_APIC_BASE, base | 0x800)
    escribir64(estado(), pagMapearDispositivo(acpiLapicFisica()))
    // Vector espurio 0xFF y APIC habilitado por software (bit 8).
    lapicEscribir(LAPIC_ESPURIO, 0x100 | VECTOR_ESPURIO)
}

// Mide con el HPET cuántas cuentas del temporizador (divisor 16) y cuántos
// ciclos de TSC hay en 10 ms.
expose flow lapicCalibrar() {
    lapicEscribir(LAPIC_DIVISOR, 3)
    lapicEscribir(LAPIC_LVT_TEMPORIZADOR, 0x10000 | VECTOR_TEMPORIZADOR)
    lapicEscribir(LAPIC_CUENTA_INICIAL, 0xFFFFFFFF)
    hold tsc0 = rdtsc()
    hpetEsperar(10000)
    hold restantes = lapicLeer(LAPIC_CUENTA_ACTUAL)
    hold tsc1 = rdtsc()
    lapicEscribir(LAPIC_CUENTA_INICIAL, 0)
    escribir64(estado() + 16, (0xFFFFFFFF - restantes) / 10)
    escribir64(estado() + 24, (tsc1 - tsc0) / 10)
}

// Temporizador periódico cada `ms` milisegundos (vector 64).
expose flow lapicTemporizadorPeriodico(ms: Int) {
    lapicEscribir(LAPIC_DIVISOR, 3)
    lapicEscribir(LAPIC_LVT_TEMPORIZADOR, 0x20000 | VECTOR_TEMPORIZADOR)
    lapicEscribir(LAPIC_CUENTA_INICIAL, lapicCuentasPorMs() * ms)
}

flow ioapicEscribir(registro: Int, valor: Int) {
    hold io = leer64(estado() + 8)
    escribir32(io, registro)
    escribir32(io + 0x10, valor)
}

expose flow ioapicIniciar() {
    escribir64(estado() + 8, pagMapearDispositivo(acpiIoapicFisica()))
}

// Dirige la IRQ ISA `irq` (con su ISO de ACPI) al `vector` del LAPIC
// `destino`. Polaridad y disparo según las banderas MPS de la ISO.
expose flow ioapicDirigirIrq(irq: Int, vector: Int, destino: Int) {
    hold gsi = acpiGsiDeIrq(irq)
    hold banderas = acpiBanderasDeIrq(irq)
    change bajo = vector
    when banderas & 3 == 3 { bajo = bajo | 0x2000 }    // activa en bajo
    when (banderas >> 2) & 3 == 3 { bajo = bajo | 0x8000 }   // por nivel
    hold entrada = 0x10 + 2 * (gsi - acpiIoapicBase())
    ioapicEscribir(entrada + 1, destino << 24)
    ioapicEscribir(entrada, bajo)
}
