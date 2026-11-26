// Framebuffer lineal de 32 bits por píxel que entrega el cargador.

take nucleo.mem
take arranque.limine
take lib.fuente

// Estado: +0 dirección, +8 ancho, +16 alto, +24 bytes por fila.
flow estado() => Int {
    give reservar(32, 8)
}

expose flow pantallaAncho() => Int { give leer64(estado() + 8) }
expose flow pantallaAlto() => Int { give leer64(estado() + 16) }

// false si no hay framebuffer o no es de 32 bits por píxel.
expose flow pantallaIniciar() => Bool {
    hold fb = arranqueFramebuffer()
    when fb == 0 || leer16(fb + 32) != 32 { give false }
    hold e = estado()
    escribir64(e, leer64(fb))
    escribir64(e + 8, leer64(fb + 8))
    escribir64(e + 16, leer64(fb + 16))
    escribir64(e + 24, leer64(fb + 24))
    give true
}

expose flow pantallaPixel(x: Int, y: Int, color: Int) {
    hold e = estado()
    escribir32(leer64(e) + y * leer64(e + 24) + x * 4, color)
}

// Rellena el rectángulo [x, x+ancho) x [y, y+alto) de `color` (0xRRGGBB).
expose flow pantallaRectangulo(x: Int, y: Int, ancho: Int, alto: Int, color: Int) {
    hold e = estado()
    hold base = leer64(e)
    hold fila = leer64(e + 24)
    hold doble = color | (color << 32)
    each j among y..(y + alto) {
        change p = base + j * fila + x * 4
        change resto = ancho
        during resto >= 2 {
            escribir64(p, doble)
            p += 8
            resto -= 2
        }
        when resto == 1 { escribir32(p, color) }
    }
}

expose flow pantallaLimpiar(color: Int) {
    pantallaRectangulo(0, 0, pantallaAncho(), pantallaAlto(), color)
}

// Dibuja el glifo 8x16 de `cp` con la esquina superior izquierda en (x, y).
expose flow pantallaGlifo(x: Int, y: Int, cp: Int, tinta: Int, fondo: Int) {
    hold e = estado()
    hold base = leer64(e)
    hold fila = leer64(e + 24)
    hold glifo = fuenteGlifo(cp)
    each j among 0..16 {
        hold bits = leer8(glifo + j)
        hold p = base + (y + j) * fila + x * 4
        each i among 0..8 {
            when bits & (0x80 >> i) != 0 {
                escribir32(p + i * 4, tinta)
            } otherwise {
                escribir32(p + i * 4, fondo)
            }
        }
    }
}

// Desplaza todo el contenido `alto` filas de píxeles hacia arriba y limpia
// la franja inferior con `fondo`.
expose flow pantallaSubir(alto: Int, fondo: Int) {
    hold e = estado()
    hold base = leer64(e)
    hold fila = leer64(e + 24)
    hold total = leer64(e + 16)
    hold bytes = (total - alto) * fila
    change i = 0
    during i < bytes {
        escribir64(base + i, leer64(base + i + alto * fila))
        i += 8
    }
    pantallaRectangulo(0, total - alto, pantallaAncho(), alto, fondo)
}
