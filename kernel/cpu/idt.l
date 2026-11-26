// IDT de 256 puertas. Cada puerta apunta al stub que genera el compilador
// (`stubInterrupcion(v)`): guarda los registros y llama a
// `kinterrupcion(marco)` (cpu/interrupciones.l).

take nucleo.cpu
take nucleo.mem
take cpu.gdt

flow tabla() => Int { give reservar(4096, 16) }
flow registroIdt() => Int { give reservar(16, 16) }

// Puerta de interrupción (tipo 0xE, presente, DPL 0) hacia `destino`,
// usando la pila IST `ist` (0 = la pila actual).
flow puerta(vector: Int, destino: Int, ist: Int) {
    hold e = tabla() + vector * 16
    hold bajo = (destino & 0xFFFF) | (SELECTOR_CODIGO << 16) | ((ist & 7) << 32) | (0x8E << 40) | (((destino >> 16) & 0xFFFF) << 48)
    escribir64(e, bajo)
    escribir64(e + 8, (destino >> 32) & 0xFFFFFFFF)
}

expose flow idtIniciar() {
    each v among 0..256 {
        change ist = 0
        // Doble falta en su propia pila (IST1 de la TSS).
        when v == 8 { ist = 1 }
        puerta(v, stubInterrupcion(v), ist)
    }
    hold r = registroIdt()
    escribir16(r, 4096 - 1)
    escribir64(r + 2, tabla())
    lidt(r)
}

expose flow idtCargarEnAp() {
    lidt(registroIdt())
}
