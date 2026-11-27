// Teclado PS/2 con distribución latinoamericana (es-LA).
//
// El controlador 8042 entrega el conjunto de códigos 1 (traducido). Cada
// interrupción (IRQ1 -> vector 65) lee un byte del puerto 0x60. Se manejan
// Mayús, Bloq Mayús, AltGr (E0 38) y las teclas muertas ´ y ¨. Los
// caracteres (puntos de código Unicode) quedan en un búfer circular.

take nucleo.cpu
take nucleo.mem

fixed DATOS = 0x60
fixed ESTADO = 0x64
fixed CAPACIDAD = 256

expose fixed TECLA_INTRO = 10
expose fixed TECLA_BORRAR = 8

// Estado: +0 mayús, +8 altgr, +16 bloq mayús, +24 prefijo E0,
// +32 tecla muerta pendiente (0, 0xB4 ´ o 0xA8 ¨), +40 lectura, +48 escritura,
// +56 bytes por interrupción, +64 bytes por sondeo, +72 último estado 0x64 visto.
flow estado() => Int { give reservar(80, 8) }
// CAPACIDAD palabras de 8 bytes.
flow bufer() => Int { give reservar(2048, 8) }

expose flow tecladoIniciar() {
    hold e = estado()
    each i among 0..10 { escribir64(e + i * 8, 0) }
    // Vaciar lo que haya en el búfer de salida del controlador.
    during in8(ESTADO) & 1 == 1 {
        hold descartado = in8(DATOS)
    }
}

flow guardar(cp: Int) {
    hold e = estado()
    hold w = leer64(e + 48)
    when (w + 1) % CAPACIDAD == leer64(e + 40) { give }
    escribir64(bufer() + w * 8, cp)
    escribir64(e + 48, (w + 1) % CAPACIDAD)
}

// Siguiente carácter tecleado, o -1 si no hay.
expose flow tecladoLeer() => Int {
    hold e = estado()
    hold r = leer64(e + 40)
    when r == leer64(e + 48) { give -1 }
    hold cp = leer64(bufer() + r * 8)
    escribir64(e + 40, (r + 1) % CAPACIDAD)
    give cp
}

// Letra de la fila de letras (sin mayúscula), o 0.
flow letra(sc: Int) => Int {
    when sc == 0x10 { give 113 }  // q
    when sc == 0x11 { give 119 }  // w
    when sc == 0x12 { give 101 }  // e
    when sc == 0x13 { give 114 }  // r
    when sc == 0x14 { give 116 }  // t
    when sc == 0x15 { give 121 }  // y
    when sc == 0x16 { give 117 }  // u
    when sc == 0x17 { give 105 }  // i
    when sc == 0x18 { give 111 }  // o
    when sc == 0x19 { give 112 }  // p
    when sc == 0x1E { give 97 }   // a
    when sc == 0x1F { give 115 }  // s
    when sc == 0x20 { give 100 }  // d
    when sc == 0x21 { give 102 }  // f
    when sc == 0x22 { give 103 }  // g
    when sc == 0x23 { give 104 }  // h
    when sc == 0x24 { give 106 }  // j
    when sc == 0x25 { give 107 }  // k
    when sc == 0x26 { give 108 }  // l
    when sc == 0x27 { give 0xF1 } // ñ
    when sc == 0x2C { give 122 }  // z
    when sc == 0x2D { give 120 }  // x
    when sc == 0x2E { give 99 }   // c
    when sc == 0x2F { give 118 }  // v
    when sc == 0x30 { give 98 }   // b
    when sc == 0x31 { give 110 }  // n
    when sc == 0x32 { give 109 }  // m
    give 0
}

// Resto de teclas: `nivel` 0 normal, 1 mayús, 2 AltGr. 0 = nada.
flow simbolo(sc: Int, nivel: Int) => Int {
    when sc >= 0x02 && sc <= 0x0B {
        // 1..9, 0 / ! " # $ % & / ( ) =
        when nivel == 0 {
            when sc == 0x0B { give 48 }
            give 48 + sc - 1
        }
        when nivel == 1 {
            when sc == 0x02 { give 33 }
            when sc == 0x03 { give 34 }
            when sc == 0x04 { give 35 }
            when sc == 0x05 { give 36 }
            when sc == 0x06 { give 37 }
            when sc == 0x07 { give 38 }
            when sc == 0x08 { give 47 }
            when sc == 0x09 { give 40 }
            when sc == 0x0A { give 41 }
            give 61
        }
        give 0
    }
    when sc == 0x29 {
        when nivel == 0 { give 124 }    // |
        when nivel == 1 { give 0xB0 }   // °
        give 0xAC                       // ¬
    }
    when sc == 0x0C {
        when nivel == 0 { give 39 }     // '
        when nivel == 1 { give 63 }     // ?
        give 92                         // \
    }
    when sc == 0x0D {
        when nivel == 0 { give 0xBF }   // ¿
        when nivel == 1 { give 0xA1 }   // ¡
        give 0
    }
    when sc == 0x1B {
        when nivel == 0 { give 43 }     // +
        when nivel == 1 { give 42 }     // *
        give 126                        // ~
    }
    when sc == 0x28 {
        when nivel == 0 { give 123 }    // {
        when nivel == 1 { give 91 }     // [
        give 94                         // ^
    }
    when sc == 0x2B {
        when nivel == 0 { give 125 }    // }
        when nivel == 1 { give 93 }     // ]
        give 96                         // `
    }
    when sc == 0x56 {
        when nivel == 0 { give 60 }     // <
        when nivel == 1 { give 62 }     // >
        give 0
    }
    when sc == 0x33 {
        when nivel == 1 { give 59 }     // ;
        give 44                         // ,
    }
    when sc == 0x34 {
        when nivel == 1 { give 58 }     // :
        give 46                         // .
    }
    when sc == 0x35 {
        when nivel == 1 { give 95 }     // _
        give 45                         // -
    }
    when sc == 0x39 { give 32 }
    when sc == 0x1C { give TECLA_INTRO }
    when sc == 0x0E { give TECLA_BORRAR }
    when sc == 0x0F { give 9 }
    give 0
}

// Vocal con tilde (´) o diéresis (¨); 0 si no se combina.
flow combinar(muerta: Int, cp: Int) => Int {
    when muerta == 0xB4 {
        when cp == 97 { give 0xE1 }
        when cp == 101 { give 0xE9 }
        when cp == 105 { give 0xED }
        when cp == 111 { give 0xF3 }
        when cp == 117 { give 0xFA }
        when cp == 65 { give 0xC1 }
        when cp == 69 { give 0xC9 }
        when cp == 73 { give 0xCD }
        when cp == 79 { give 0xD3 }
        when cp == 85 { give 0xDA }
    }
    when muerta == 0xA8 {
        when cp == 117 { give 0xFC }
        when cp == 85 { give 0xDC }
        when cp == 105 { give 0xEF }
    }
    give 0
}

flow pulsar(sc: Int) {
    hold e = estado()
    hold mayus = leer64(e) == 1
    hold altgr = leer64(e + 8) == 1
    // Tecla muerta ´ / ¨ (0x1A).
    when sc == 0x1A && !altgr {
        when mayus { escribir64(e + 32, 0xA8) } otherwise { escribir64(e + 32, 0xB4) }
        give
    }
    change cp = 0
    hold l = letra(sc)
    when l != 0 {
        when altgr {
            when sc == 0x10 { cp = 64 }    // AltGr+Q = @
        } otherwise {
            change mayuscula = mayus
            when leer64(e + 16) == 1 { mayuscula = !mayuscula }
            cp = l
            when mayuscula {
                when l == 0xF1 { cp = 0xD1 } otherwise { cp = l - 32 }
            }
        }
    } otherwise {
        change nivel = 0
        when mayus { nivel = 1 }
        when altgr { nivel = 2 }
        cp = simbolo(sc, nivel)
    }
    when cp == 0 { give }
    hold muerta = leer64(e + 32)
    when muerta != 0 {
        escribir64(e + 32, 0)
        hold combinado = combinar(muerta, cp)
        when combinado != 0 {
            guardar(combinado)
            give
        }
        // Espacio tras la tecla muerta: el acento solo.
        guardar(muerta)
        when cp == 32 { give }
    }
    guardar(cp)
}

// Atiende la IRQ1: un byte de código de exploración.
expose flow tecladoInterrupcion() {
    hold e = estado()
    // Sin dato (el sondeo ya lo tomó): no leer, devolvería el byte anterior.
    when in8(ESTADO) & 1 == 0 { give }
    escribir64(e + 56, leer64(e + 56) +% 1)
    tecladoProcesar(in8(DATOS))
}

// Sondeo de respaldo: si la IRQ1 no llega, lee el 8042 directamente. Con las
// interrupciones cerradas para no competir con la IRQ por el puerto 0x60.
// Devuelve true si procesó un byte del teclado.
expose flow tecladoSondear() => Bool {
    hold e = estado()
    when in8(ESTADO) & 1 == 0 { give false }
    // Hay dato: con interrupciones abiertas se da margen a que la IRQ lo tome.
    each i among 0..2000 { pause() }
    cli()
    hold st = in8(ESTADO)
    escribir64(e + 72, st)
    change tomado = false
    when st & 1 == 1 {
        hold b = in8(DATOS)
        // Bit 5 (AUX): dato del ratón, se descarta.
        when st & 0x20 == 0 {
            escribir64(e + 64, leer64(e + 64) +% 1)
            tecladoProcesar(b)
            tomado = true
        }
    }
    sti()
    give tomado
}

expose flow tecladoPorInterrupcion() => Int { give leer64(estado() + 56) }
expose flow tecladoPorSondeo() => Int { give leer64(estado() + 64) }
expose flow tecladoUltimoEstado() => Int { give leer64(estado() + 72) }

// Traduce un byte de código de exploración (común a IRQ y sondeo).
flow tecladoProcesar(sc: Int) {
    hold e = estado()
    when sc == 0xE0 {
        escribir64(e + 24, 1)
        give
    }
    hold extendido = leer64(e + 24) == 1
    escribir64(e + 24, 0)
    hold soltar = sc & 0x80 != 0
    hold tecla = sc & 0x7F
    when extendido {
        when tecla == 0x38 {
            when soltar { escribir64(e + 8, 0) } otherwise { escribir64(e + 8, 1) }
        }
        give
    }
    when tecla == 0x2A || tecla == 0x36 {
        when soltar { escribir64(e, 0) } otherwise { escribir64(e, 1) }
        give
    }
    when tecla == 0x3A && !soltar {
        escribir64(e + 16, 1 - leer64(e + 16))
        give
    }
    when !soltar { pulsar(tecla) }
}
