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
fixed MAX_ENTRADAS = 256
flow copia() => Int { give reservar(6272, 8) }

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
