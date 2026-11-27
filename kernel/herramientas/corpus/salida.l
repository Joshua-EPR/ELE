// Salidas: índices ELEIDX01, archivos de tipos, README sellado y ESTADISTICAS.md.
take util

fixed MAGIA: Int = 0x3130584449454C45     // "ELEIDX01" en little-endian

flow volcarPalabra(b: edit List of[Int], n: Int, w: Int) => Int {
    each j among 0..8 {
        poner(edit b, n + j, (w >> (j * 8)) & 255)
    }
    give n + 8
}

flow docsDe(g: view List of[Int], p: Int) => Int {
    give g[S_DOCS + p * 2] + g[S_DOCS + p * 2 + 1]
}

// Escribe un índice con formato ELEIDX01 versión 1 (el que lee el kernel).
// La sección "entrena" es la partición pA; la sección "prueba" es pB, o queda
// vacía si pB < 0. Con pB < 0 también escribe el archivo de tipos (1 byte por
// documento: 0 TEXTO, 1 DIALOGO), cuyo CRC32C y nº de diálogos van en las
// palabras 11 y 10 de la cabecera (reservadas, a cero en el formato original).
expose flow escribirIndice(ruta: view Text, rutaTipos: view Text, meta: view List of[Int], g: view List of[Int], k: view List of[Int], b: edit List of[Int], pA: Int, pB: Int) => Int {
    hold nA = docsDe(g, pA)
    change nB = 0
    change bytesB = 0
    change crcB = 0
    when pB >= 0 {
        nB = docsDe(g, pB)
        bytesB = g[S_OFF + pB]
        crcB = crcFinal(g[S_CRC + pB])
    }
    // CRC de la tabla (en el orden de escritura) y de los tipos.
    change ct = 0xFFFFFFFF
    change cty = 0xFFFFFFFF
    change dialogos = 0
    hold nm = meta.length / 4
    change pasada = 0
    during pasada < 2 {
        change pp = pA
        when pasada == 1 { pp = pB }
        when pp >= 0 {
            each d among 0..nm {
                when meta[d * 4] == pp {
                    ct = crcPalabra(k, ct, meta[d * 4 + 1])
                    ct = crcPalabra(k, ct, meta[d * 4 + 2])
                    when pasada == 0 && pB < 0 {
                        hold t = meta[d * 4 + 3]
                        dialogos += t
                        poner(edit b, 0, t)
                        cty = crcLista(k, cty, view b, 1)
                    }
                }
            }
        }
        pasada += 1
    }
    change hw: List of[Int] = List[]
    hw@push(MAGIA)
    hw@push(1)
    hw@push(nA)
    hw@push(nB)
    hw@push(g[S_OFF + pA])
    hw@push(crcFinal(g[S_CRC + pA]))
    hw@push(bytesB)
    hw@push(crcB)
    hw@push(crcFinal(ct))
    // CRC de las palabras 0..8 (72 bytes).
    change ch = 0xFFFFFFFF
    each j among 0..9 {
        ch = crcPalabra(k, ch, hw[j])
    }
    hw@push(crcFinal(ch))
    when pB < 0 {
        hw@push(dialogos)
        hw@push(crcFinal(cty))
    } otherwise {
        hw@push(0)
        hw@push(0)
    }
    each j among 12..16 {
        hw@push(0)
    }
    hold f = fileOpen(ruta, 2)
    when fileStatus(f) != 0 {
        hold st = fileStatus(f)
        fileClose(f)
        give st
    }
    change bn = 0
    change r = 0
    each j among 0..16 {
        bn = volcarPalabra(edit b, bn, hw[j])
    }
    change pas2 = 0
    during pas2 < 2 && r == 0 {
        change pp = pA
        when pas2 == 1 { pp = pB }
        when pp >= 0 {
            change d = 0
            during d < nm && r == 0 {
                when meta[d * 4] == pp {
                    bn = volcarPalabra(edit b, bn, meta[d * 4 + 1])
                    bn = volcarPalabra(edit b, bn, meta[d * 4 + 2])
                    when bn >= 65000 {
                        when fileWrite(f, b, bn) != bn { r = 0 - 5 }
                        bn = 0
                    }
                }
                d += 1
            }
        }
        pas2 += 1
    }
    when r == 0 && bn > 0 {
        when fileWrite(f, b, bn) != bn { r = 0 - 5 }
    }
    hold c = fileClose(f)
    when r != 0 { give r }
    when c != 0 { give c }
    when pB >= 0 { give 0 }
    // Archivo de tipos.
    change tl: List of[Int] = List[]
    each d among 0..nm {
        when meta[d * 4] == pA {
            tl@push(meta[d * 4 + 3])
        }
    }
    give guardarLista(rutaTipos, view tl, tl.length)
}

// Carácter legible para la tabla de frecuencias.
flow emitirCaracter(md: edit List of[Int], cp: Int) {
    when cp == 10 {
        emitirT(edit md, "salto de línea")
    } otherwise when cp == 32 {
        emitirT(edit md, "espacio")
    } otherwise when cp == 124 {
        emitirT(edit md, "`\\|`")
    } otherwise when cp == 96 {
        emitirT(edit md, "acento grave")
    } otherwise when cp < 32 || cp == 127 {
        emitirT(edit md, "control")
    } otherwise {
        md@push(96)
        emitirCp(edit md, cp)
        md@push(96)
    }
}

flow fila(md: edit List of[Int], etiqueta: Text, v: Int) {
    emitirT(edit md, "| ")
    emitirT(edit md, etiqueta)
    emitirT(edit md, " | ")
    emitirN(edit md, v)
    emitirT(edit md, " |\n")
}

// Extracto de ~300 bytes de un documento de entrenamiento, en bloque de código.
flow extracto(f: view File, off: Int, largo: Int, buf: edit List of[Int], md: edit List of[Int]) {
    change ini = off
    when largo > 600 { ini = off + largo / 3 }
    hold quedan = off + largo - ini
    change m = 304
    when quedan < m { m = quedan }
    when fileSeek(f, ini, 0) != ini { give }
    hold got = fileRead(f, buf, m)
    when got <= 0 { give }
    change a = 0
    during a < got && (buf[a] & 0xC0) == 0x80 {
        a += 1
    }
    change e = a + 300
    when e > got { e = got }
    when e < got {
        during e > a && (buf[e] & 0xC0) == 0x80 {
            e -= 1
        }
    }
    emitirT(edit md, "~~~~\n")
    each q among a..e {
        md@push(buf[q])
    }
    when e > a && buf[e - 1] != 10 {
        md@push(10)
    }
    emitirT(edit md, "~~~~\n\n")
}

expose flow escribirEstadisticas(rutaMd: view Text, rutaE: view Text, meta: view List of[Int], g: view List of[Int], k: edit List of[Int], b: edit List of[Int]) => Int {
    change md: List of[Int] = List[]
    emitirT(edit md, "# Estadísticas del corpus\n\n")
    emitirT(edit md, "Generado por `kernel/herramientas/corpus/preparar.l` (Fase 4, hito 23). Determinista: la misma lista de archivos y las mismas opciones dan los mismos bytes.\n\n")
    emitirT(edit md, "## Parámetros\n\n| parámetro | valor |\n|---|---|\n")
    fila(edit md, "mínimo de un documento de texto (bytes)", g[O_MIN])
    fila(edit md, "mínimo de un diálogo (bytes)", g[O_MIND])
    fila(edit md, "umbral de no textuales (por mil de los caracteres)", g[O_BASURA])
    fila(edit md, "mínimo de letras (% de los caracteres visibles)", g[O_LETRAS])
    fila(edit md, "similitud de casi duplicado (%)", g[O_SIM])
    fila(edit md, "reparar mojibake (1 sí, 0 no)", g[O_MOJI])
    fila(edit md, "semilla de la partición", g[O_SEMILLA])
    fila(edit md, "% prueba", g[O_PRUEBA])
    fila(edit md, "% validación", g[O_VALIDA])
    fila(edit md, "tamaño máximo de un documento (bytes)", g[O_MAXDOC])
    fila(edit md, "máximo de documentos conservados", g[O_MAXDOCS])
    emitirT(edit md, "\n## Entrada\n\n| concepto | valor |\n|---|---|\n")
    fila(edit md, "archivos leídos", g[C_ARCH])
    fila(edit md, "archivos no legibles", g[C_ILEG])
    fila(edit md, "bytes leídos", g[C_ENTRADA])
    fila(edit md, "líneas `=====` (separadores de documentos)", g[C_SEPARADORES])
    fila(edit md, "documentos partidos por superar el tamaño máximo", g[C_PARTES])
    fila(edit md, "documentos crudos examinados", g[C_CRUDOS])
    emitirT(edit md, "\n## Particiones\n\n")
    emitirT(edit md, "| partición | documentos | TEXTO | DIALOGO | bytes | bytes TEXTO | bytes DIALOGO | media (bytes/doc) | CRC32C |\n|---|---|---|---|---|---|---|---|---|\n")
    each p among 0..3 {
        hold nd = docsDe(g, p)
        when p == 0 {
            emitirT(edit md, "| entrena | ")
        } otherwise when p == 1 {
            emitirT(edit md, "| valida | ")
        } otherwise {
            emitirT(edit md, "| prueba (sellada) | ")
        }
        emitirN(edit md, nd)
        emitirT(edit md, " | ")
        emitirN(edit md, g[S_DOCS + p * 2])
        emitirT(edit md, " | ")
        emitirN(edit md, g[S_DOCS + p * 2 + 1])
        emitirT(edit md, " | ")
        emitirN(edit md, g[S_OFF + p])
        emitirT(edit md, " | ")
        emitirN(edit md, g[S_BYTES + p * 2])
        emitirT(edit md, " | ")
        emitirN(edit md, g[S_BYTES + p * 2 + 1])
        emitirT(edit md, " | ")
        when nd > 0 {
            emitirN(edit md, g[S_OFF + p] / nd)
        } otherwise {
            emitirT(edit md, "0")
        }
        emitirT(edit md, " | ")
        emitirHex(edit md, crcFinal(g[S_CRC + p]), 8)
        emitirT(edit md, " |\n")
    }
    emitirT(edit md, "\nProporciones: ")
    hold totalB = g[S_OFF] + g[S_OFF + 1] + g[S_OFF + 2]
    emitirT(edit md, "entrena ")
    emitirPorcentaje(edit md, g[S_OFF], totalB)
    emitirT(edit md, ", valida ")
    emitirPorcentaje(edit md, g[S_OFF + 1], totalB)
    emitirT(edit md, ", prueba ")
    emitirPorcentaje(edit md, g[S_OFF + 2], totalB)
    emitirT(edit md, " de los bytes conservados.\n")
    emitirT(edit md, "\n## Descartes por motivo\n\n| motivo | documentos |\n|---|---|\n")
    fila(edit md, "cortos (texto)", g[C_CORTOS])
    fila(edit md, "cortos (diálogo)", g[C_CORTOS + 1])
    fila(edit md, "basura: caracteres no textuales o U+FFFD sobre el umbral", g[C_BASURA])
    fila(edit md, "basura: pocas letras (tablas, listas de números)", g[C_LETRAS])
    fila(edit md, "mojibake no reparable", g[C_MOJIBAKE])
    fila(edit md, "duplicados exactos", g[C_EXACTOS])
    fila(edit md, "casi duplicados (MinHash + LSH)", g[C_CASI])
    emitirT(edit md, "\n## Conversiones y limpieza (sobre los documentos examinados)\n\n| concepto | cantidad |\n|---|---|\n")
    fila(edit md, "documentos convertidos de Windows-1252 a UTF-8", g[C_CP1252])
    fila(edit md, "documentos con mojibake reparado", g[C_REPAR])
    fila(edit md, "BOM UTF-8 quitados", g[C_BOM])
    fila(edit md, "documentos con CR (CRLF o CR convertidos a LF)", g[C_CR])
    fila(edit md, "caracteres de control quitados", g[C_CTRL])
    fila(edit md, "U+FFFD presentes", g[C_FFD])
    emitirT(edit md, "\n## Memoria de las tablas de duplicados\n\n| tabla | bytes |\n|---|---|\n")
    fila(edit md, "exactos (hash de 64 bits, direccionamiento abierto)", g[M_EX])
    fila(edit md, "bandas LSH (8 por documento)", g[M_BAND])
    fila(edit md, "firmas MinHash (64 bytes por documento conservado, reservadas)", g[M_SIG])
    emitirT(edit md, "\n## Los 40 puntos de código más frecuentes (entrenamiento)\n\n")
    // Los ASCII se contaron por byte (K_BF); se pasan a la tabla de puntos de código.
    each c among 0..128 {
        k[K_FREQ + c] = k[K_BF + c]
    }
    change total = 0
    each c among 0..65537 {
        total += k[K_FREQ + c]
    }
    emitirT(edit md, "Total de caracteres de entrenamiento: ")
    emitirN(edit md, total)
    emitirT(edit md, ".\n\n| # | punto de código | carácter | cuenta | proporción |\n|---|---|---|---|---|\n")
    each r among 0..40 {
        change mejor = 0 - 1
        change mc = 0
        each c among 0..65537 {
            when k[K_FREQ + c] > mc {
                mc = k[K_FREQ + c]
                mejor = c
            }
        }
        when mejor < 0 { leave }
        emitirT(edit md, "| ")
        emitirN(edit md, r + 1)
        when mejor == 65536 {
            emitirT(edit md, " | U+10000..10FFFF | (fuera del plano básico) | ")
        } otherwise {
            emitirT(edit md, " | U+")
            emitirHex(edit md, mejor, 4)
            emitirT(edit md, " | ")
            emitirCaracter(edit md, mejor)
            emitirT(edit md, " | ")
        }
        emitirN(edit md, mc)
        emitirT(edit md, " | ")
        emitirPorcentaje(edit md, mc, total)
        emitirT(edit md, " |\n")
        k[K_FREQ + mejor] = 0 - 1
    }
    emitirT(edit md, "\n## Tres extractos de entrenamiento (~300 bytes)\n\n")
    hold nm = meta.length / 4
    hold nt = docsDe(g, 0)
    when nt > 0 {
        hold fe = fileOpen(rutaE, 1)
        when fileStatus(fe) == 0 {
            each q among 0..3 {
                // Documento de entrenamiento número 0, nt/2 y nt-1.
                change objetivo = 0
                when q == 1 { objetivo = nt / 2 }
                when q == 2 { objetivo = nt - 1 }
                change visto = 0
                change d = 0
                change off = 0 - 1
                change largo = 0
                change tipo = 0
                during d < nm && off < 0 {
                    when meta[d * 4] == 0 {
                        when visto == objetivo {
                            off = meta[d * 4 + 1]
                            largo = meta[d * 4 + 2]
                            tipo = meta[d * 4 + 3]
                        }
                        visto += 1
                    }
                    d += 1
                }
                when off >= 0 {
                    emitirT(edit md, "Documento ")
                    emitirN(edit md, objetivo)
                    emitirT(edit md, " de entrenamiento (")
                    when tipo == 1 {
                        emitirT(edit md, "DIALOGO")
                    } otherwise {
                        emitirT(edit md, "TEXTO")
                    }
                    emitirT(edit md, ", ")
                    emitirN(edit md, largo)
                    emitirT(edit md, " bytes):\n\n")
                    extracto(fe, off, largo, edit b, edit md)
                }
            }
        }
        fileClose(fe)
    }
    give guardarLista(rutaMd, view md, md.length)
}

// Aviso que acompaña a la prueba sellada.
expose flow escribirAvisoPrueba(ruta: view Text) => Int {
    change md: List of[Int] = List[]
    emitirT(edit md, "# Prueba sellada\n\n")
    emitirT(edit md, "Esta carpeta contiene el 1 % de los documentos reservado para la **prueba final** de la Fase 4 (`prueba.bin`, `prueba.idx`, `prueba.tipos`).\n\n")
    emitirT(edit md, "- **No se abre, no se entrena, no se ajustan umbrales ni hiperparámetros con ella** hasta el final de la fase.\n")
    emitirT(edit md, "- Los ajustes se hacen con `valida.bin`. La prueba se usa una sola vez, al terminar, para el número final.\n")
    emitirT(edit md, "- No copies esta carpeta a la partición ELEDATOS del kernel ni la incluyas en la imagen hasta ese momento.\n")
    emitirT(edit md, "- Si hay que regenerar el corpus (otra lista de archivos u otros umbrales), la prueba cambia: apunta los CRC32C de `ESTADISTICAS.md` para saber qué prueba es.\n")
    give guardarLista(ruta, view md, md.length)
}
