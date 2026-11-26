// Puerto serie COM1 (UART 16550 en 0x3F8): 115200 baudios, 8N1, sin
// interrupciones. Es la primera salida del kernel y la usan los hitos
// siguientes para depurar.

take nucleo.cpu

fixed COM1 = 0x3F8

// Registros relativos a la base del UART.
fixed UART_DATOS = 0           // THR/RBR (con DLAB=1: divisor bajo)
fixed UART_INTERRUPCIONES = 1  // IER (con DLAB=1: divisor alto)
fixed UART_FIFO = 2            // FCR
fixed UART_LINEA = 3           // LCR
fixed UART_MODEM = 4           // MCR
fixed UART_ESTADO = 5          // LSR

fixed LSR_TRANSMISOR_VACIO = 0x20

expose flow serieIniciar() {
    out8(COM1 + UART_INTERRUPCIONES, 0x00)   // sin interrupciones
    out8(COM1 + UART_LINEA, 0x80)            // DLAB=1 para fijar el divisor
    out8(COM1 + UART_DATOS, 0x01)            // divisor 1 -> 115200 baudios
    out8(COM1 + UART_INTERRUPCIONES, 0x00)
    out8(COM1 + UART_LINEA, 0x03)            // 8 bits, sin paridad, 1 stop
    out8(COM1 + UART_FIFO, 0xC7)             // FIFO activo, limpio, umbral 14
    out8(COM1 + UART_MODEM, 0x0B)            // DTR, RTS, OUT2
}

expose flow serieByte(b: Int) {
    during in8(COM1 + UART_ESTADO) & LSR_TRANSMISOR_VACIO == 0 {
        pause()
    }
    out8(COM1 + UART_DATOS, b)
}
