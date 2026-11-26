// Generador aleatorio determinista PCG32 (O'Neill, XSH-RR) con semilla:
// misma semilla, misma secuencia, en cualquier núcleo y arranque.

take nucleo.mem

fixed MULTIPLICADOR = 6364136223846793005

// Un generador es un bloque de 16 bytes: +0 estado, +8 incremento (impar).
expose flow pcgSembrar(g: Int, semilla: Int, secuencia: Int) {
    escribir64(g, 0)
    escribir64(g + 8, (secuencia << 1) | 1)
    hold primero = pcgSiguiente(g)
    escribir64(g, leer64(g) +% semilla)
    hold segundo = pcgSiguiente(g)
}

// Siguiente valor de 32 bits (0 .. 2^32-1).
expose flow pcgSiguiente(g: Int) => Int {
    hold viejo = leer64(g)
    escribir64(g, viejo *% MULTIPLICADOR +% leer64(g + 8))
    hold desplazado = (((viejo >> 18) ^ viejo) >> 27) & 0xFFFFFFFF
    hold rotacion = viejo >> 59
    give ((desplazado >> rotacion) | (desplazado << ((32 - rotacion) & 31))) & 0xFFFFFFFF
}

// Uniforme en [0, 1).
expose flow pcgUniforme(g: Int) => Float {
    give Float(pcgSiguiente(g)) / 4294967296.0
}

// Uniforme en [a, b).
expose flow pcgEntre(g: Int, a: Float, b: Float) => Float {
    give a + (b - a) * pcgUniforme(g)
}

// Entero en [0, n).
expose flow pcgEntero(g: Int, n: Int) => Int {
    give pcgSiguiente(g) % n
}
