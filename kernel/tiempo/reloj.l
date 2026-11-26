// Reloj de referencia: el HPET si existe; si no, el temporizador PM de ACPI
// (3,579545 MHz, 24 o 32 bits). Sirve para calibrar el LAPIC y el TSC y
// para las esperas cortas del arranque SMP.

take nucleo.cpu
take nucleo.mem
take dispositivos.acpi
take tiempo.hpet

expose fixed RELOJ_NINGUNO = 0
expose fixed RELOJ_HPET = 1
expose fixed RELOJ_PM = 2
fixed FRECUENCIA_PM = 3579545

// Estado: +0 fuente, +8 puerto PM, +16 máscara del contador PM,
// +24 última lectura PM, +32 tics PM acumulados.
flow estado() => Int { give reservar(40, 8) }

expose flow relojFuente() => Int { give leer64(estado()) }

// Elige la fuente. Devuelve RELOJ_HPET, RELOJ_PM o RELOJ_NINGUNO.
expose flow relojIniciar() => Int {
    hold e = estado()
    when hpetIniciar(acpiHpetFisica()) {
        escribir64(e, RELOJ_HPET)
        give RELOJ_HPET
    }
    hold puerto = acpiPuertoPm()
    when puerto == 0 {
        escribir64(e, RELOJ_NINGUNO)
        give RELOJ_NINGUNO
    }
    escribir64(e, RELOJ_PM)
    escribir64(e + 8, puerto)
    when acpiPm32Bits() { escribir64(e + 16, 0xFFFFFFFF) } otherwise { escribir64(e + 16, 0xFFFFFF) }
    escribir64(e + 24, in32(puerto) & leer64(e + 16))
    escribir64(e + 32, 0)
    give RELOJ_PM
}

expose flow relojFrecuencia() => Int {
    when relojFuente() == RELOJ_HPET { give hpetFrecuencia() }
    when relojFuente() == RELOJ_PM { give FRECUENCIA_PM }
    give 0
}

// Nanosegundos desde un origen fijo. Con el temporizador PM hay que leerlo
// al menos una vez cada ~4 s (vuelta del contador de 24 bits).
expose flow relojNanosegundos() => Int {
    hold e = estado()
    when leer64(e) == RELOJ_HPET { give hpetNanosegundos(hpetContador()) }
    when leer64(e) != RELOJ_PM { give 0 }
    hold mascara = leer64(e + 16)
    hold ahora = in32(leer64(e + 8)) & mascara
    hold tics = leer64(e + 32) + ((ahora - leer64(e + 24)) & mascara)
    escribir64(e + 24, ahora)
    escribir64(e + 32, tics)
    give tics / FRECUENCIA_PM * 1000000000 + tics % FRECUENCIA_PM * 1000000000 / FRECUENCIA_PM
}

// Espera activa de `us` microsegundos.
expose flow relojEsperar(us: Int) {
    hold inicio = relojNanosegundos()
    during relojNanosegundos() - inicio < us * 1000 { pause() }
}
