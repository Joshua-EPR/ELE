// Interfaz `arranque` implementada con el protocolo Limine.
//
// El resto del kernel solo usa las flows `arranque*` de este módulo; si un
// día cambia el cargador, se reemplaza este archivo y nada más.
//
// Las peticiones son bloques de `datos64` en .data. Limine recorre la imagen
// cargada buscando sus identificadores (alineados a 8 bytes) y, antes de
// saltar a kmain, escribe en la palabra 5 (desplazamiento 40) un puntero a
// la respuesta, o lo deja en 0 si no la atiende.

take nucleo.mem

fixed LIMINE_COMUN_0 = 0xC7B1DD30DF4C8B88
fixed LIMINE_COMUN_1 = 0x0A82E883A194F07B
fixed RESPUESTA = 40

// Revisión base 3. Limine pone la tercera palabra a 0 si la admite.
flow revisionBase() => Int {
    give datos64(0xF9562B2D5C95A6C8, 0x6A7B384944536BDC, 3)
}

flow peticionFramebuffer() => Int {
    give datos64(LIMINE_COMUN_0, LIMINE_COMUN_1, 0x9D5827DCD881DD75, 0xA3148604F6FAB11B, 0, 0)
}

flow peticionHhdm() => Int {
    give datos64(LIMINE_COMUN_0, LIMINE_COMUN_1, 0x48DCF1CB8AD2B852, 0x63984E959A98244B, 0, 0)
}

flow peticionMemoria() => Int {
    give datos64(LIMINE_COMUN_0, LIMINE_COMUN_1, 0x67CF3D9D378A806F, 0xE304ACDFC50C3C62, 0, 0)
}

flow peticionRsdp() => Int {
    give datos64(LIMINE_COMUN_0, LIMINE_COMUN_1, 0xC5E77B6B397E7B43, 0x27637845ACCDCF3C, 0, 0)
}

flow peticionDireccionKernel() => Int {
    give datos64(LIMINE_COMUN_0, LIMINE_COMUN_1, 0x71BA76863CC55F63, 0xB2644A48C516A487, 0, 0)
}

// Executable Cmdline (Limine >= 9): la respuesta trae en +8 un puntero a la
// cadena terminada en 0 con la línea de órdenes de la entrada del menú.
flow peticionLineaOrdenes() => Int {
    give datos64(LIMINE_COMUN_0, LIMINE_COMUN_1, 0x4B161536E598651E, 0xB390AD4A2F1F303A, 0, 0)
}

flow respuesta(peticion: Int) => Int {
    give leer64(peticion + RESPUESTA)
}

// Copia propia de todo lo que el kernel usa de Limine. Las respuestas viven
// en memoria "recuperable del cargador": tras arranqueCopiar() el kernel ya
// no las lee y esa memoria se puede liberar (mem.fisica).
//   +0 revisión aceptada (1/0)  +8 HHDM (-1 si no hay)  +16 RSDP
//   +24 kernel física  +32 kernel virtual  +40 hay framebuffer (1/0)
//   +48 entradas del mapa de memoria  +64.. framebuffer (64 bytes)
//   +128.. mapa de memoria: hasta 256 entradas de 24 bytes
//   +6272 línea de órdenes (registro de cadena: +0 longitud, +8 bytes)
//   +6536 valor de la última opción pedida (mismo formato)
fixed MAX_ENTRADAS = 256
fixed LINEA = 6272
fixed VALOR = 6536
fixed MAX_LINEA = 255
flow copia() => Int { give reservar(6800, 8) }

flow copiar64(origen: Int, destino: Int, bytes: Int) {
    change i = 0
    during i < bytes {
        escribir64(destino + i, leer64(origen + i))
        i += 8
    }
}

expose flow arranqueCopiar() {
    hold c = copia()
    change aceptada = 0
    when leer64(revisionBase() + 16) == 0 { aceptada = 1 }
    escribir64(c, aceptada)

    hold hhdm = respuesta(peticionHhdm())
    change desplazamiento = -1
    when hhdm != 0 { desplazamiento = leer64(hhdm + 8) }
    escribir64(c + 8, desplazamiento)

    hold rsdp = respuesta(peticionRsdp())
    change dir_rsdp = 0
    when rsdp != 0 { dir_rsdp = leer64(rsdp + 8) }
    escribir64(c + 16, dir_rsdp)

    hold kernel = respuesta(peticionDireccionKernel())
    escribir64(c + 24, 0)
    escribir64(c + 32, 0)
    when kernel != 0 {
        escribir64(c + 24, leer64(kernel + 8))
        escribir64(c + 32, leer64(kernel + 16))
    }

    hold fb = respuesta(peticionFramebuffer())
    escribir64(c + 40, 0)
    when fb != 0 && leer64(fb + 8) != 0 {
        copiar64(leer64(leer64(fb + 16)), c + 64, 64)
        escribir64(c + 40, 1)
    }

    hold mapa = respuesta(peticionMemoria())
    change n = 0
    when mapa != 0 { n = leer64(mapa + 8) }
    when n > MAX_ENTRADAS { n = MAX_ENTRADAS }
    each i among 0..n {
        copiar64(leer64(leer64(mapa + 16) + i * 8), c + 128 + i * 24, 24)
    }
    escribir64(c + 48, n)

    // Línea de órdenes: copia propia (hasta 255 bytes), vacía si no hay.
    escribir64(c + LINEA, 0)
    escribir64(c + VALOR, 0)
    hold cmd = respuesta(peticionLineaOrdenes())
    when cmd != 0 {
        hold texto = leer64(cmd + 8)
        when texto != 0 {
            change k = 0
            during k < MAX_LINEA && leer8(texto + k) != 0 {
                escribir8(c + LINEA + 8 + k, leer8(texto + k))
                k += 1
            }
            escribir64(c + LINEA, k)
        }
    }
}

// true si Limine aceptó la revisión base 3 del protocolo.
expose flow arranqueRevisionAceptada() => Bool {
    give leer64(copia()) == 1
}

// Dirección de la copia de la estructura del primer framebuffer, o 0.
//   +0 dirección, +8 ancho, +16 alto, +24 bytes por fila, +32 bits por
//   píxel (u16), +34 modelo de memoria (1 = RGB), +35..+40 tamaño y
//   desplazamiento de las máscaras R, G, B (u8).
expose flow arranqueFramebuffer() => Int {
    when leer64(copia() + 40) == 0 { give 0 }
    give copia() + 64
}

// Desplazamiento del mapa directo de la memoria física (HHDM): la física
// `f` se ve en la virtual `f + arranqueHhdm()`. -1 si no hay respuesta.
expose flow arranqueHhdm() => Int {
    give leer64(copia() + 8)
}

expose flow arranqueMemoriaCantidad() => Int {
    give leer64(copia() + 48)
}

// Entrada `i` del mapa de memoria: +0 base, +8 longitud, +16 tipo
// (MEMORIA_*).
expose flow arranqueMemoriaEntrada(i: Int) => Int {
    give copia() + 128 + i * 24
}

expose fixed MEMORIA_USABLE = 0
expose fixed MEMORIA_RESERVADA = 1
expose fixed MEMORIA_ACPI_RECUPERABLE = 2
expose fixed MEMORIA_ACPI_NVS = 3
expose fixed MEMORIA_DEFECTUOSA = 4
expose fixed MEMORIA_CARGADOR_RECUPERABLE = 5
expose fixed MEMORIA_KERNEL = 6
expose fixed MEMORIA_FRAMEBUFFER = 7

// Dirección física de la RSDP de ACPI (revisión base 3), o 0.
expose flow arranqueRsdp() => Int {
    give leer64(copia() + 16)
}

// Base física y virtual donde se cargó el kernel (0 si no hay respuesta).
expose flow arranqueKernelFisica() => Int {
    give leer64(copia() + 24)
}

expose flow arranqueKernelVirtual() => Int {
    give leer64(copia() + 32)
}

// Línea de órdenes del kernel como registro de cadena (kprint la imprime);
// longitud 0 si no hay.
expose flow arranqueLinea() => Int {
    give copia() + LINEA
}

// Opciones "clave=valor" separadas por espacios. Devuelve el valor de la
// opción `clave` (registro de cadena, válido hasta la siguiente llamada) o 0
// si no está. Una clave sin "=" da un valor vacío.
expose flow arranqueOpcion(clave: Int) => Int {
    hold linea = copia() + LINEA
    hold n = leer64(linea)
    hold kn = leer64(clave)
    change i = 0
    during i < n {
        during i < n && leer8(linea + 8 + i) == 32 { i += 1 }
        hold ini = i
        during i < n && leer8(linea + 8 + i) != 32 { i += 1 }
        hold fin = i
        change igual = fin > ini
        change e = ini
        during e < fin && leer8(linea + 8 + e) != 61 { e += 1 }
        when e - ini != kn { igual = false }
        when igual {
            each j among 0..kn {
                when leer8(linea + 8 + ini + j) != leer8(clave + 8 + j) { igual = false }
            }
        }
        when igual {
            change vi = e
            when e < fin { vi = e + 1 }
            hold vn = fin - vi
            escribir64(copia() + VALOR, vn)
            each j among 0..vn {
                escribir8(copia() + VALOR + 8 + j, leer8(linea + 8 + vi + j))
            }
            give copia() + VALOR
        }
    }
    give 0
}

// true si la opción `clave` está y vale exactamente `valor` (registro de cadena).
expose flow arranqueOpcionEs(clave: Int, valor: Int) => Bool {
    hold v = arranqueOpcion(clave)
    when v == 0 { give false }
    when leer64(v) != leer64(valor) { give false }
    each j among 0..leer64(valor) {
        when leer8(v + 8 + j) != leer8(valor + 8 + j) { give false }
    }
    give true
}
