// HPET: contador principal de frecuencia fija, el reloj de referencia
// para calibrar el temporizador del LAPIC y el TSC.

take nucleo.cpu
take nucleo.mem
take mem.paginacion

// Estado: +0 dirección virtual de los registros, +8 periodo en femtosegundos.
flow estado() => Int { give reservar(16, 8) }

expose flow hpetIniciar(fisica: Int) => Bool {
    when fisica == 0 { give false }
    hold r = pagMapearDispositivo(fisica)
    hold periodo = leer64(r) >> 32
    when periodo == 0 || periodo > 100000000 { give false }
    escribir64(estado(), r)
    escribir64(estado() + 8, periodo)
    // Configuración general (+0x10): ENABLE_CNF.
    escribir64(r + 0x10, leer64(r + 0x10) | 1)
    give true
}

expose flow hpetContador() => Int {
    give leer64(leer64(estado()) + 0xF0)
}

// Nanosegundos que representan `ticks` del contador.
expose flow hpetNanosegundos(ticks: Int) => Int {
    give ticks * (leer64(estado() + 8) / 1000) / 1000
}

expose flow hpetFrecuencia() => Int {
    give 1000000000000000 / leer64(estado() + 8)
}

// Espera activa de `us` microsegundos.
expose flow hpetEsperar(us: Int) {
    hold objetivo = hpetContador() + us * 1000000000 / leer64(estado() + 8)
    during hpetContador() < objetivo { pause() }
}
