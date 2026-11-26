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

// true si Limine aceptó la revisión base 3 del protocolo.
expose flow arranqueRevisionAceptada() => Bool {
    give leer64(revisionBase() + 16) == 0
}

// Dirección de la estructura del primer framebuffer, o 0.
//   +0 dirección, +8 ancho, +16 alto, +24 bytes por fila, +32 bits por
//   píxel (u16), +34 modelo de memoria (1 = RGB), +35..+40 tamaño y
//   desplazamiento de las máscaras R, G, B (u8).
expose flow arranqueFramebuffer() => Int {
    hold r = respuesta(peticionFramebuffer())
    when r == 0 || leer64(r + 8) == 0 { give 0 }
    give leer64(leer64(r + 16))
}

// Desplazamiento del mapa directo de la memoria física (HHDM): la física
// `f` se ve en la virtual `f + arranqueHhdm()`. -1 si no hay respuesta.
expose flow arranqueHhdm() => Int {
    hold r = respuesta(peticionHhdm())
    when r == 0 { give -1 }
    give leer64(r + 8)
}

expose flow arranqueMemoriaCantidad() => Int {
    hold r = respuesta(peticionMemoria())
    when r == 0 { give 0 }
    give leer64(r + 8)
}

// Entrada `i` del mapa de memoria: +0 base, +8 longitud, +16 tipo
// (MEMORIA_*).
expose flow arranqueMemoriaEntrada(i: Int) => Int {
    hold r = respuesta(peticionMemoria())
    give leer64(leer64(r + 16) + i * 8)
}

expose fixed MEMORIA_USABLE = 0
expose fixed MEMORIA_RESERVADA = 1
expose fixed MEMORIA_ACPI_RECUPERABLE = 2
expose fixed MEMORIA_ACPI_NVS = 3
expose fixed MEMORIA_DEFECTUOSA = 4
expose fixed MEMORIA_CARGADOR_RECUPERABLE = 5
expose fixed MEMORIA_KERNEL = 6
expose fixed MEMORIA_FRAMEBUFFER = 7

// Dirección (virtual, según la revisión del protocolo) de la RSDP de ACPI,
// o 0.
expose flow arranqueRsdp() => Int {
    hold r = respuesta(peticionRsdp())
    when r == 0 { give 0 }
    give leer64(r + 8)
}

// Base física y virtual donde se cargó el kernel (0 si no hay respuesta).
expose flow arranqueKernelFisica() => Int {
    hold r = respuesta(peticionDireccionKernel())
    when r == 0 { give 0 }
    give leer64(r + 8)
}

expose flow arranqueKernelVirtual() => Int {
    hold r = respuesta(peticionDireccionKernel())
    when r == 0 { give 0 }
    give leer64(r + 16)
}
