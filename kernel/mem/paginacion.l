// Tablas de páginas propias (4 niveles, x86-64).
//
// pagIniciar construye un PML4 nuevo con:
//   - el HHDM de toda la memoria que describe Limine (salvo la reservada y
//     la defectuosa) con páginas de 2 MiB, el framebuffer incluido;
//   - la imagen del kernel en la mitad alta, con páginas de 4 KiB;
// y lo carga en CR3. Los MMIO (APIC, HPET) se añaden luego con
// pagMapear4k / pagMapearDispositivo.

take nucleo.cpu
take nucleo.mem
take arranque.limine
take mem.fisica

expose fixed PAG_PRESENTE = 1
expose fixed PAG_ESCRITURA = 2
expose fixed PAG_SIN_CACHE = 0x18   // PCD + PWT
fixed PAG_GRANDE = 0x80
fixed MASCARA_DIRECCION = 0x000FFFFFFFFFF000

// Estado: +0 PML4 física.
flow estado() => Int { give reservar(8, 8) }

expose flow pagPml4() => Int { give leer64(estado()) }

// Entrada de la tabla siguiente para `indice` en la tabla `tabla` (física);
// la crea si no existe. Devuelve la física de la tabla hija, o 0.
flow siguiente(tabla: Int, indice: Int) => Int {
    hold e = memVirtual(tabla) + indice * 8
    hold v = leer64(e)
    // Una página grande (2 MiB) ya cubre esta zona: no hay tabla debajo.
    when v & PAG_PRESENTE != 0 && v & PAG_GRANDE != 0 { give 0 }
    when v & PAG_PRESENTE != 0 { give v & MASCARA_DIRECCION }
    hold nueva = memFisicaReservar()
    when nueva == 0 { give 0 }
    escribir64(e, nueva | PAG_PRESENTE | PAG_ESCRITURA)
    give nueva
}

flow indice(virtual: Int, nivel: Int) => Int {
    give (virtual >> (12 + 9 * nivel)) & 511
}

// Página de 4 KiB virtual -> física con `banderas` (además de presente).
expose flow pagMapear4k(virtual: Int, fisica: Int, banderas: Int) => Bool {
    hold pdpt = siguiente(pagPml4(), indice(virtual, 3))
    when pdpt == 0 { give false }
    hold pd = siguiente(pdpt, indice(virtual, 2))
    when pd == 0 { give false }
    hold pt = siguiente(pd, indice(virtual, 1))
    when pt == 0 { give false }
    escribir64(memVirtual(pt) + indice(virtual, 0) * 8, (fisica & MASCARA_DIRECCION) | banderas | PAG_PRESENTE)
    invlpg(virtual)
    give true
}

// Página de 2 MiB (ambas direcciones alineadas a 2 MiB).
flow mapear2m(virtual: Int, fisica: Int, banderas: Int) => Bool {
    hold pdpt = siguiente(pagPml4(), indice(virtual, 3))
    when pdpt == 0 { give false }
    hold pd = siguiente(pdpt, indice(virtual, 2))
    when pd == 0 { give false }
    hold e = memVirtual(pd) + indice(virtual, 1) * 8
    when leer64(e) & PAG_PRESENTE == 0 {
        escribir64(e, (fisica & MASCARA_DIRECCION) | banderas | PAG_GRANDE | PAG_PRESENTE)
    }
    give true
}

// MMIO de un dispositivo: la página física `fisica` en el HHDM, sin caché.
// Devuelve su dirección virtual.
expose flow pagMapearDispositivo(fisica: Int) => Int {
    hold base = fisica & (~0xFFF)
    hold v = memVirtual(base)
    // Si una página grande del HHDM ya la cubre, se usa tal cual.
    hold mapeada = pagMapear4k(v, base, PAG_ESCRITURA | PAG_SIN_CACHE)
    give memVirtual(fisica)
}

expose flow pagIniciar() => Bool {
    hold pml4 = memFisicaReservar()
    when pml4 == 0 { give false }
    escribir64(estado(), pml4)
    hold hhdm = memHhdm()
    hold dos_mb = 2097152

    // HHDM con páginas de 2 MiB.
    hold n = arranqueMemoriaCantidad()
    each i among 0..n {
        hold ent = arranqueMemoriaEntrada(i)
        hold tipo = leer64(ent + 16)
        when tipo != MEMORIA_RESERVADA && tipo != MEMORIA_DEFECTUOSA {
            change p = leer64(ent) / dos_mb * dos_mb
            hold fin = leer64(ent) + leer64(ent + 8)
            during p < fin {
                change banderas = PAG_ESCRITURA
                when tipo == MEMORIA_FRAMEBUFFER { banderas = PAG_ESCRITURA | PAG_SIN_CACHE }
                when !mapear2m(hhdm + p, p, banderas) { give false }
                p += dos_mb
            }
        }
    }

    // Imagen del kernel: la entrada KERNEL que contiene su base física.
    hold fisica = arranqueKernelFisica()
    hold virtual = arranqueKernelVirtual()
    change tamano = 0
    each i among 0..n {
        hold ent = arranqueMemoriaEntrada(i)
        when leer64(ent + 16) == MEMORIA_KERNEL && fisica >= leer64(ent) && fisica < leer64(ent) + leer64(ent + 8) {
            tamano = leer64(ent) + leer64(ent + 8) - fisica
        }
    }
    when fisica == 0 || tamano == 0 { give false }
    change d = 0
    during d < tamano {
        when !pagMapear4k(virtual + d, fisica + d, PAG_ESCRITURA) { give false }
        d += MARCO
    }

    escribirCr3(pml4)
    give true
}
