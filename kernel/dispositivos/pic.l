// PIC 8259 heredado. Se reprograma a los vectores 32..47 (para que sus IRQ
// no se confundan con excepciones) y se enmascara entero: las interrupciones
// de dispositivos llegarán por el APIC (hito 6).

take nucleo.cpu

fixed PIC1_ORDEN = 0x20
fixed PIC1_DATOS = 0x21
fixed PIC2_ORDEN = 0xA0
fixed PIC2_DATOS = 0xA1

// Pausa breve para el PIC: escritura al puerto 0x80 (POST).
flow esperar() {
    out8(0x80, 0)
}

expose flow picReprogramarYEnmascarar() {
    out8(PIC1_ORDEN, 0x11)   // ICW1: inicializar, con ICW4
    esperar()
    out8(PIC2_ORDEN, 0x11)
    esperar()
    out8(PIC1_DATOS, 32)     // ICW2: base de vectores
    esperar()
    out8(PIC2_DATOS, 40)
    esperar()
    out8(PIC1_DATOS, 4)      // ICW3: esclavo en IRQ2
    esperar()
    out8(PIC2_DATOS, 2)
    esperar()
    out8(PIC1_DATOS, 1)      // ICW4: modo 8086
    esperar()
    out8(PIC2_DATOS, 1)
    esperar()
    out8(PIC1_DATOS, 0xFF)   // todo enmascarado
    out8(PIC2_DATOS, 0xFF)
}

expose flow picFinInterrupcion(irq: Int) {
    when irq >= 8 { out8(PIC2_ORDEN, 0x20) }
    out8(PIC1_ORDEN, 0x20)
}
