// CPUID, activación de SSE y prueba de FXSAVE/FXRSTOR.
//
// Objetivo: Celeron 3865U (Kaby Lake) — SSE hasta SSE4.2, sin AVX ni FMA.
// Nunca se activa XSAVE/AVX: CR4.OSXSAVE queda a 0, así que cualquier
// instrucción VEX daría #UD (el compilador tampoco puede emitirlas).

take nucleo.cpu
take nucleo.mem
take lib.consola

flow buffer() => Int { give reservar(16, 16) }
flow areaFx() => Int { give reservar(512, 16) }

// Registros de la última llamada: +0 EAX, +4 EBX, +8 ECX, +12 EDX.
flow consultar(hoja: Int, subhoja: Int) => Int {
    hold b = buffer()
    cpuid(hoja, subhoja, b)
    give b
}

flow bit(valor: Int, n: Int) => Bool {
    give (valor >> n) & 1 == 1
}

flow imprimirBytes(dir: Int, cuantos: Int) {
    each i among 0..cuantos {
        hold c = leer8(dir + i)
        when c != 0 { kprintByte(c) }
    }
}

flow marca(nombre: Int, presente: Bool) {
    kprintByte(32)
    kprint(nombre)
    when presente { kprintByte(43) } otherwise { kprintByte(45) }
}

// Imprime fabricante, modelo y extensiones. Devuelve false si falta algo
// imprescindible (SSE2 o FXSR).
expose flow cpuInforme() => Bool {
    hold r = consultar(0, 0)
    hold maxima = leer32(r)
    kprint(cadena("CPU: "))
    hold texto = reservar(48, 16)
    escribir32(texto, leer32(r + 4))
    escribir32(texto + 4, leer32(r + 12))
    escribir32(texto + 8, leer32(r + 8))
    imprimirBytes(texto, 12)

    hold ext = consultar(0x80000000, 0)
    when leer32(ext) >= 0x80000004 {
        kprint(cadena(" / "))
        each k among 0..3 {
            hold q = consultar(0x80000002 + k, 0)
            each j among 0..4 { escribir32(texto + k * 16 + j * 4, leer32(q + j * 4)) }
        }
        imprimirBytes(texto, 48)
    }
    kprintByte(10)

    hold uno = consultar(1, 0)
    hold ecx = leer32(uno + 8)
    hold edx = leer32(uno + 12)
    change avx2 = false
    when maxima >= 7 { avx2 = bit(leer32(consultar(7, 0) + 4), 5) }
    kprint(cadena("  extensiones:"))
    marca(cadena("SSE"), bit(edx, 25))
    marca(cadena("SSE2"), bit(edx, 26))
    marca(cadena("SSE3"), bit(ecx, 0))
    marca(cadena("SSSE3"), bit(ecx, 9))
    marca(cadena("SSE4.1"), bit(ecx, 19))
    marca(cadena("SSE4.2"), bit(ecx, 20))
    marca(cadena("POPCNT"), bit(ecx, 23))
    marca(cadena("FXSR"), bit(edx, 24))
    kprintByte(10)
    kprint(cadena("  no se usan:"))
    marca(cadena("AVX"), bit(ecx, 28))
    marca(cadena("AVX2"), avx2)
    marca(cadena("FMA"), bit(ecx, 12))
    marca(cadena("XSAVE"), bit(ecx, 26))
    kprintByte(10)
    give bit(edx, 26) && bit(edx, 24)
}

// CR0: EM=0, MP=1. CR4: OSFXSR y OSXMMEXCPT. CR4.OSXSAVE no se toca.
expose flow cpuActivarSse() {
    hold cr0 = leerCr0()
    escribirCr0((cr0 & (~0x4)) | 0x2)
    hold cr4 = leerCr4()
    escribirCr4(cr4 | 0x200 | 0x400)
}

// FXSAVE guarda el estado; se comprueba MXCSR (+24) y se restaura.
// Devuelve el MXCSR leído.
expose flow cpuProbarFxsave() => Int {
    hold a = areaFx()
    fxsave(a)
    hold mxcsr = leer32(a + 24)
    fxrstor(a)
    give mxcsr
}
