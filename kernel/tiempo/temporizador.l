// Reloj del sistema: tics del temporizador del LAPIC.

take nucleo.cpu
take nucleo.mem

// Estado: +0 tics desde que arrancó el temporizador, +8 milisegundos por tic.
flow estado() => Int { give reservar(16, 8) }

expose flow temporizadorConfigurar(ms_por_tic: Int) {
    escribir64(estado(), 0)
    escribir64(estado() + 8, ms_por_tic)
}

// Llamado desde kinterrupcion en cada interrupción del temporizador.
expose flow temporizadorTic() {
    escribir64(estado(), leer64(estado()) + 1)
}

expose flow temporizadorTics() => Int { give leer64(estado()) }

expose flow temporizadorMilisegundos() => Int {
    give leer64(estado()) * leer64(estado() + 8)
}

// Duerme la CPU hasta que pasen `ms` milisegundos (requiere STI).
expose flow temporizadorDormir(ms: Int) {
    hold objetivo = temporizadorMilisegundos() + ms
    during temporizadorMilisegundos() < objetivo { hlt() }
}
