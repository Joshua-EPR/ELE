// Buzones de trabajo entre núcleos y barrera ligera.
//
// Cada núcleo i (0 = BSP) tiene una línea de caché propia de 64 bytes:
//   +0 secuencia pedida   +8 secuencia hecha   +16 código   +24 argumento
//   +32 barrera: última generación alcanzada
// No hay instrucciones atómicas: cada campo lo escribe un solo núcleo y x86
// mantiene el orden de las escrituras (TSO); el compilador emite cada
// acceso a memoria tal cual, en orden.

take nucleo.cpu
take nucleo.mem

expose fixed MAX_NUCLEOS = 8
fixed LINEA = 64

// +0 núcleos en línea (BSP incluido); los buzones empiezan en +64.
flow zona() => Int { give reservar(LINEA * (MAX_NUCLEOS + 1), 64) }
flow buzon(nucleo: Int) => Int { give zona() + LINEA + nucleo * LINEA }

expose flow buzonNucleos() => Int {
    hold n = leer64(zona())
    when n < 1 { give 1 }
    give n
}

expose flow buzonFijarNucleos(n: Int) {
    escribir64(zona(), n)
}

// BSP: encarga a `nucleo` el trabajo `codigo` con `argumento`.
expose flow buzonPublicar(nucleo: Int, codigo: Int, argumento: Int) {
    hold b = buzon(nucleo)
    escribir64(b + 16, codigo)
    escribir64(b + 24, argumento)
    escribir64(b, leer64(b) + 1)
}

// BSP: espera a que `nucleo` termine lo último que se le encargó.
expose flow buzonEsperarFin(nucleo: Int) {
    hold b = buzon(nucleo)
    during leer64(b + 8) != leer64(b) { pause() }
}

// AP: espera un trabajo nuevo; devuelve la dirección del buzón (código en
// +16, argumento en +24).
expose flow buzonEsperarTrabajo(nucleo: Int) => Int {
    hold b = buzon(nucleo)
    during leer64(b + 8) == leer64(b) { pause() }
    give b
}

expose flow buzonTerminar(nucleo: Int) {
    hold b = buzon(nucleo)
    escribir64(b + 8, leer64(b))
}

// Barrera entre los núcleos 0..n-1: cada uno anuncia `generacion` y espera
// a que todos la alcancen. La generación debe crecer en cada uso.
expose flow buzonBarrera(nucleo: Int, n: Int, generacion: Int) {
    escribir64(buzon(nucleo) + 32, generacion)
    each i among 0..n {
        during leer64(buzon(i) + 32) < generacion { pause() }
    }
}
