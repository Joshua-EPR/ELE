// ENCA: perfilador por componentes con rdtsc. No cambia ningún resultado:
// solo suma ciclos en una tabla. Con PERFIL = 0 las llamadas no hacen nada.
//
// Fases: 0 vigilia, 1 sueño, 2 evaluación, 3 autocompletado.
// Tabla (8 bytes por campo): +0 fase actual; +8 + fase*8 pasos;
// +64 + (fase*16 + componente)*8 ciclos. Cada ranura la escribe un solo
// núcleo (el 0, salvo los componentes del hipocampo en el modo rápido).

take nucleo.cpu
take nucleo.mem
take lib.consola

expose fixed PERFIL = 1

expose fixed PF_HIP_PRED = 0
expose fixed PF_HIP_APR = 1
expose fixed PF_COR_AVANZAR = 2
expose fixed PF_COR_LECTURA = 3
expose fixed PF_MEZ_PRED = 4
expose fixed PF_MEZ_ACT = 5
expose fixed PF_COR_APR = 6
expose fixed PF_REPLAY = 7
expose fixed PF_METRICAS = 8
expose fixed PF_ESPERA = 9
expose fixed PF_VENTANA = 10
expose fixed PF_AVA_A = 11
expose fixed PF_AVA_B = 12
expose fixed PF_AVA_C = 13
expose fixed PF_AVA_D = 14
expose fixed PF_AVA_E = 15
fixed COMPONENTES = 16

flow tabla() => Int { give reservar(64 + 4 * 16 * 8, 64) }

expose flow perfilFase(fase: Int) {
    when PERFIL == 1 { escribir64(tabla(), fase) }
}

expose flow perfilFaseActual() => Int { give leer64(tabla()) }

expose flow perfilReiniciar() {
    when PERFIL == 1 {
        hold t = tabla()
        each i among 0..(64 + 4 * 16 * 8) / 8 { escribir64(t + i * 8, 0) }
    }
}

// Cuenta un paso del modelo en la fase actual.
expose flow perfilPaso() {
    when PERFIL == 1 {
        hold t = tabla()
        hold p = t + 8 + leer64(t) * 8
        escribir64(p, leer64(p) + 1)
    }
}

expose flow perfilIni() => Int {
    when PERFIL == 1 { give rdtsc() }
    give 0
}

// Suma `n` (una cuenta, no ciclos) a un componente.
expose flow perfilContar(componente: Int, n: Int) {
    when PERFIL == 1 {
        hold t = tabla()
        hold p = t + 64 + (leer64(t) * 16 + componente) * 8
        escribir64(p, leer64(p) + n)
    }
}

expose flow perfilFin(componente: Int, t0: Int) {
    when PERFIL == 1 {
        hold t = tabla()
        hold p = t + 64 + (leer64(t) * 16 + componente) * 8
        escribir64(p, leer64(p) + (rdtsc() - t0))
    }
}

flow nombre(c: Int) => Int {
    when c == 0 { give cadena("hipocampo: predicción ") }
    when c == 1 { give cadena("hipocampo: aprendizaje") }
    when c == 2 { give cadena("corteza: sinapsis+kWTA ") }
    when c == 3 { give cadena("corteza: logits+softmax") }
    when c == 4 { give cadena("mezclador: predicción  ") }
    when c == 5 { give cadena("mezclador: actualización") }
    when c == 6 { give cadena("corteza: aprendizaje   ") }
    when c == 7 { give cadena("replay (control)       ") }
    when c == 8 { give cadena("métricas               ") }
    when c == 9 { give cadena("espera entre núcleos   ") }
    when c == 11 { give cadena("  avance: etapa A (SSE)  ") }
    when c == 12 { give cadena("  avance: B1 cota        ") }
    when c == 13 { give cadena("  avance: B2 k-WTA       ") }
    when c == 14 { give cadena("  (cuenta) lanes revisados") }
    when c == 15 { give cadena("  (cuenta) inserciones   ") }
    give cadena("ventana                ")
}

flow imprimirPorMil(pm: Int) {
    kprintEntero(pm / 10)
    kprintByte(46)
    kprintEntero(pm % 10)
    kprint(cadena(" %"))
}

// Tabla de una fase. `ciclos` = ciclos totales de la fase (medidos aparte).
expose flow perfilImprimir(fase: Int, titulo: Int, ciclos: Int) {
    when PERFIL != 1 { give }
    hold t = tabla()
    hold pasos = leer64(t + 8 + fase * 8)
    when pasos < 1 || ciclos < 1 { give }
    kprint(cadena("perfil "))
    kprint(titulo)
    kprint(cadena(": "))
    kprintEntero(pasos)
    kprint(cadena(" pasos, "))
    kprintEntero(ciclos / pasos)
    kprintln(cadena(" ciclos/paso"))
    change suma = 0
    each c among 0..COMPONENTES {
        hold v = leer64(t + 64 + (fase * 16 + c) * 8)
        when v > 0 {
            suma += v
            kprint(cadena("    "))
            kprint(nombre(c))
            kprint(cadena(" "))
            kprintEntero(v / pasos)
            kprint(cadena(" ciclos/paso  "))
            imprimirPorMil(v * 1000 / ciclos)
            kprintByte(10)
        }
    }
    kprint(cadena("    suma de componentes / total de la fase: "))
    imprimirPorMil(suma * 1000 / ciclos)
    kprintByte(10)
}
