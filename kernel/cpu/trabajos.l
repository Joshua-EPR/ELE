// Despacho de trabajos de los procesadores secundarios (cpu/buzon.l).
// Sin punteros a función: cada código de trabajo tiene su rama aquí.

take lib.sgemm

expose flow trabajoEjecutar(codigo: Int, argumento: Int, nucleo: Int) {
    when codigo == TRABAJO_SGEMM { sgemmParte(argumento, nucleo) }
}
