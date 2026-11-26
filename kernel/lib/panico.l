// Parada del kernel por una condición que nunca debe ocurrir (por ejemplo,
// un intento de escribir el disco fuera de la partición permitida).

take nucleo.cpu
take nucleo.mem
take lib.consola

expose flow panico(motivo: Int) {
    cli()
    kprint(cadena("\n*** pánico del kernel: "))
    kprintln(motivo)
    kprintln(cadena("*** sistema detenido"))
    during true { hlt() }
}
