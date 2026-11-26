// Consola del kernel: kprint escribe a la vez en COM1 y en el framebuffer
// (si lo hay), con salto de línea y desplazamiento hacia arriba.
//
// Los textos son registros de `cadena("...")`: +0 número de bytes, +8 los
// bytes UTF-8. En pantalla se dibujan U+0000..U+00FF (ASCII y Latin-1); el
// resto se ve como '?'. COM1 recibe los bytes tal cual.

take nucleo.mem
take dispositivos.serie
take dispositivos.pantalla

fixed TINTA = 0xD8DEE9
fixed FONDO = 0x1B2330

// Estado: +0 columna, +8 fila, +16 columnas, +24 filas, +32 hay pantalla,
// +40 punto de código UTF-8 en curso, +48 bytes de continuación que faltan.
flow estado() => Int {
    give reservar(64, 8)
}

expose flow consolaIniciar() {
    serieIniciar()
    hold e = estado()
    when pantallaIniciar() {
        escribir64(e + 16, pantallaAncho() / 8)
        escribir64(e + 24, pantallaAlto() / 16)
        escribir64(e + 32, 1)
        pantallaLimpiar(FONDO)
    }
}

expose flow consolaTienePantalla() => Bool {
    give leer64(estado() + 32) == 1
}

flow nuevaLinea() {
    hold e = estado()
    escribir64(e, 0)
    hold fila = leer64(e + 8) + 1
    when fila >= leer64(e + 24) {
        pantallaSubir(16, FONDO)
        escribir64(e + 8, leer64(e + 24) - 1)
    } otherwise {
        escribir64(e + 8, fila)
    }
}

flow dibujar(cp: Int) {
    hold e = estado()
    when leer64(e) >= leer64(e + 16) { nuevaLinea() }
    pantallaGlifo(leer64(e) * 8, leer64(e + 8) * 16, cp, TINTA, FONDO)
    escribir64(e, leer64(e) + 1)
}

// Un byte de texto UTF-8.
expose flow kprintByte(b: Int) {
    when b == 10 { serieByte(13) }
    serieByte(b)
    hold e = estado()
    when leer64(e + 32) != 1 { give }
    hold faltan = leer64(e + 48)
    when faltan > 0 && b >= 0x80 && b < 0xC0 {
        hold cp = (leer64(e + 40) << 6) | (b & 0x3F)
        escribir64(e + 40, cp)
        escribir64(e + 48, faltan - 1)
        when faltan == 1 { dibujar(cp) }
        give
    }
    escribir64(e + 48, 0)
    when b == 10 {
        nuevaLinea()
    } otherwise when b < 0x80 {
        when b >= 32 { dibujar(b) }
    } otherwise when b >= 0xC0 && b < 0xE0 {
        escribir64(e + 40, b & 0x1F)
        escribir64(e + 48, 1)
    } otherwise when b >= 0xE0 && b < 0xF0 {
        escribir64(e + 40, b & 0x0F)
        escribir64(e + 48, 2)
    } otherwise when b >= 0xF0 {
        escribir64(e + 40, b & 0x07)
        escribir64(e + 48, 3)
    }
}

// Un punto de código Unicode (se codifica en UTF-8).
expose flow kprintCaracter(cp: Int) {
    when cp < 0x80 {
        kprintByte(cp)
    } otherwise when cp < 0x800 {
        kprintByte(0xC0 | (cp >> 6))
        kprintByte(0x80 | (cp & 0x3F))
    } otherwise when cp < 0x10000 {
        kprintByte(0xE0 | (cp >> 12))
        kprintByte(0x80 | ((cp >> 6) & 0x3F))
        kprintByte(0x80 | (cp & 0x3F))
    } otherwise {
        kprintByte(0xF0 | (cp >> 18))
        kprintByte(0x80 | ((cp >> 12) & 0x3F))
        kprintByte(0x80 | ((cp >> 6) & 0x3F))
        kprintByte(0x80 | (cp & 0x3F))
    }
}

// Borra el último carácter de la línea actual (si no está al principio).
expose flow kprintRetroceso() {
    serieByte(8)
    serieByte(32)
    serieByte(8)
    hold e = estado()
    when leer64(e + 32) != 1 || leer64(e) == 0 { give }
    escribir64(e, leer64(e) - 1)
    pantallaGlifo(leer64(e) * 8, leer64(e + 8) * 16, 32, TINTA, FONDO)
}

// Escribe un registro de `cadena("...")`.
expose flow kprint(texto: Int) {
    hold n = leer64(texto)
    each i among 0..n {
        kprintByte(leer8(texto + 8 + i))
    }
}

expose flow kprintln(texto: Int) {
    kprint(texto)
    kprintByte(10)
}

// Entero con signo en decimal.
expose flow kprintEntero(valor: Int) {
    when valor == 0 {
        kprintByte(48)
        give
    }
    // Se trabaja en negativo para cubrir también Int.MIN.
    change n = valor
    when n > 0 { n = 0 - n }
    when valor < 0 { kprintByte(45) }
    hold digitos = reservar(24, 8)
    change cuantos = 0
    during n != 0 {
        escribir8(digitos + cuantos, 48 - n % 10)
        n = n / 10
        cuantos += 1
    }
    during cuantos > 0 {
        cuantos -= 1
        kprintByte(leer8(digitos + cuantos))
    }
}

// Los 64 bits en hexadecimal, con prefijo 0x y 16 cifras.
expose flow kprintHex(valor: Int) {
    kprintByte(48)
    kprintByte(120)
    each i among 0..16 {
        hold cifra = (valor >> (60 - 4 * i)) & 0xF
        when cifra < 10 {
            kprintByte(48 + cifra)
        } otherwise {
            kprintByte(55 + cifra)
        }
    }
}
