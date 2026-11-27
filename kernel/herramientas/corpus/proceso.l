// Proceso por documento: normalizar, filtrar, deduplicar, repartir y escribir.
// Los archivos se leen por bloques; ningún archivo entero se carga en memoria.
take util
take texto
take dedup
take jsonl

fixed BLOQUE: Int = 1048576

// Partición de un documento: 0 entrena, 1 valida, 2 prueba (por identidad).
flow particionDe(g: view List of[Int], idx: Int) => Int {
    hold h = mezclar(g[X_IDH] +% (idx + 1) *% 0x9E3779B97F4A7C15 ^ (g[O_SEMILLA] *% 0xD6E8FEB86659FD93))
    hold r = (h >> 1) % 100
    // Los diálogos tienen su propio reparto (por defecto 90/5/5).
    change pr = g[O_PRUEBA]
    change va = g[O_VALIDA]
    when g[X_TIPO] == 1 {
        pr = g[O_DPRU]
        va = g[O_DVAL]
    }
    when r < pr { give 2 }
    when r < pr + va { give 1 }
    give 0
}

// Escribe el documento normalizado en su partición y lo anota en `meta`.
flow emitirDoc(p: Int, nor: view List of[Int], n: Int, k: edit List of[Int], g: edit List of[Int], meta: edit List of[Int], fe: view File, fv: view File, fp: view File) {
    change w = 0
    // Los dos primeros diálogos JSONL de entrenamiento sirven de ejemplo.
    when p == 0 && g[X_JSON] == 1 && g[J_NEJ] < 2 {
        g[J_EJ + g[J_NEJ]] = g[S_DOCS] + g[S_DOCS + 1]
        g[J_NEJ] = g[J_NEJ] + 1
    }
    when p == 0 {
        w = fileWrite(fe, nor, n)
    } otherwise when p == 1 {
        w = fileWrite(fv, nor, n)
    } otherwise {
        w = fileWrite(fp, nor, n)
    }
    when w != n {
        g[X_ABORT] = 30
        give
    }
    hold tipo = g[X_TIPO]
    meta@push(p)
    meta@push(g[S_OFF + p])
    meta@push(n)
    meta@push(tipo)
    g[S_OFF + p] = g[S_OFF + p] + n
    g[S_CRC + p] = crcLista(view k, g[S_CRC + p], nor, n)
    g[S_DOCS + p * 2 + tipo] = g[S_DOCS + p * 2 + tipo] + 1
    g[S_BYTES + p * 2 + tipo] = g[S_BYTES + p * 2 + tipo] + n
    // Frecuencia de puntos de código solo en entrenamiento: un contador por
    // byte y, solo para los bytes de arranque no ASCII, el punto de código.
    when p == 0 {
        change i = 0
        during i < n {
            hold b = nor[i]
            k[K_BF + b] = k[K_BF + b] + 1
            when b >= 0xC2 {
                hold cp = cpEn(nor, i) / 8
                when cp < 65536 {
                    k[K_FREQ + cp] = k[K_FREQ + cp] + 1
                } otherwise {
                    k[K_FREQ + 65536] = k[K_FREQ + 65536] + 1
                }
            }
            i += 1
        }
    }
}

// Un documento crudo (raw[0..rn)) recorre todo el filtro.
flow procesarDoc(raw: view List of[Int], rn: Int, dec: edit List of[Int], nor: edit List of[Int], k: edit List of[Int], g: edit List of[Int], ex: edit List of[Int], sigs: edit List of[Int], bandas: edit List of[Int], meta: edit List of[Int], fe: view File, fv: view File, fp: view File) {
    hold tipo = g[X_TIPO]
    hold idx = g[X_IDX]
    g[X_IDX] = idx + 1
    g[C_CRUDOS] = g[C_CRUDOS] + 1
    // 1. Codificación: UTF-8 válido, mojibake o Windows-1252.
    change n2 = rn
    change usoDec = false
    when !esUtf8(raw, rn) {
        n2 = desdeCp1252(raw, rn, edit dec)
        usoDec = true
        g[C_CP1252] = g[C_CP1252] + 1
    } otherwise {
        when contarMoji(raw, rn) >= 3 {
            change reparado = false
            when g[O_MOJI] == 1 {
                hold r = repararMoji(raw, rn, edit dec)
                when r >= 0 && esUtf8(view dec, r) {
                    n2 = r
                    usoDec = true
                    reparado = true
                    g[C_REPAR] = g[C_REPAR] + 1
                }
            }
            when !reparado {
                g[C_MOJIBAKE] = g[C_MOJIBAKE] + 1
                give
            }
        }
    }
    // 2. Limpieza.
    change n = 0
    when usoDec {
        n = limpiar(view dec, n2, edit nor, edit g)
    } otherwise {
        n = limpiar(raw, n2, edit nor, edit g)
    }
    g[C_BOM] = g[C_BOM] + g[D_BOM]
    g[C_CR] = g[C_CR] + g[D_CR]
    g[C_CTRL] = g[C_CTRL] + g[D_CTRL]
    g[C_FFD] = g[C_FFD] + g[D_FFD]
    g[C_NFC] = g[C_NFC] + g[D_NFC]
    g[C_MARC] = g[C_MARC] + g[D_MARC]
    // 3. Basura: proporción de no textuales (controles y U+FFFD).
    when g[D_CHARS] > 0 && (g[D_CTRL] + g[D_FFD]) * 1000 > g[O_BASURA] * g[D_CHARS] {
        g[C_BASURA] = g[C_BASURA] + 1
        give
    }
    // 4. Documento demasiado corto (los diálogos admiten menos).
    change minimo = g[O_MIN]
    when tipo == 1 { minimo = g[O_MIND] }
    when n < minimo {
        g[C_CORTOS + tipo] = g[C_CORTOS + tipo] + 1
        give
    }
    // 5. Pocas letras (tablas, listas de números).
    when medirLetras(view nor, n, view k) < g[O_LETRAS] * 10 {
        g[C_LETRAS] = g[C_LETRAS] + 1
        give
    }
    // 6. Duplicados exactos y casi exactos.
    hold h = hashDoc(view nor, n)
    when exactoExiste(view ex, h) {
        g[C_EXACTOS] = g[C_EXACTOS] + 1
        give
    }
    firma(view nor, n, edit k)
    when casiExiste(view bandas, view sigs, view k, g[O_SIM]) {
        g[C_CASI] = g[C_CASI] + 1
        give
    }
    when sigs.length / 8 >= g[O_MAXDOCS] {
        g[X_ABORT] = 31
        give
    }
    exactoInsertar(edit ex, h)
    casiInsertar(edit bandas, edit sigs, view k)
    // 7. Reparto por documento y escritura.
    hold p = particionDe(view g, idx)
    emitirDoc(p, view nor, n, edit k, edit g, edit meta, fe, fv, fp)
}

// ¿La línea raw[a..b) es solo "====="? (se ignoran espacios, tab y CR)
flow esSeparador(raw: view List of[Int], a: Int, b: Int) => Bool {
    change i = a
    change j = b
    during i < j && (raw[i] == 32 || raw[i] == 9 || raw[i] == 13) {
        i += 1
    }
    during j > i && (raw[j - 1] == 32 || raw[j - 1] == 9 || raw[j - 1] == 13) {
        j -= 1
    }
    when j - i != 5 { give false }
    each q among i..j {
        when raw[q] != 61 { give false }
    }
    give true
}

// Lee un archivo por bloques y lo corta en documentos (líneas "=====").
flow procesarArchivo(ruta: view Text, blk: edit List of[Int], raw: edit List of[Int], dec: edit List of[Int], nor: edit List of[Int], k: edit List of[Int], g: edit List of[Int], ex: edit List of[Int], sigs: edit List of[Int], bandas: edit List of[Int], meta: edit List of[Int], fe: view File, fv: view File, fp: view File) => Int {
    hold f = fileOpen(ruta, 1)
    when fileStatus(f) != 0 {
        hold st = fileStatus(f)
        fileClose(f)
        g[C_ILEG] = g[C_ILEG] + 1
        give st
    }
    g[C_ARCH] = g[C_ARCH] + 1
    g[X_IDX] = 0
    change rn = 0
    change linea = 0
    change tragar = false
    change estado = 0
    hold lim = raw.length - 8
    during g[X_ABORT] == 0 {
        hold got = fileRead(f, blk, BLOQUE)
        when got < 0 {
            estado = got
            leave
        }
        when got == 0 { leave }
        g[C_ENTRADA] = g[C_ENTRADA] + got
        each j among 0..got {
            hold b = blk[j]
            // Camino común: un byte que no es salto de línea.
            when b > 13 && rn < lim {
                raw[rn] = b
                rn += 1
            } otherwise when tragar && rn == 0 && b == 10 {
                tragar = false
            } otherwise when b == 10 || b == 13 {
                when esSeparador(view raw, linea, rn) {
                    g[C_SEPARADORES] = g[C_SEPARADORES] + 1
                    when linea > 0 {
                        procesarDoc(view raw, linea, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
                    }
                    rn = 0
                    linea = 0
                    tragar = b == 13
                } otherwise {
                    raw[rn] = b
                    rn += 1
                    linea = rn
                    when rn >= g[O_MAXDOC] {
                        g[C_PARTES] = g[C_PARTES] + 1
                        procesarDoc(view raw, rn, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
                        rn = 0
                        linea = 0
                        tragar = false
                    }
                }
            } otherwise {
                // Byte de control raro, o línea más larga que el tope: corte.
                when rn >= lim && ((b & 0xC0) != 0x80 || rn >= raw.length - 1) {
                    g[C_PARTES] = g[C_PARTES] + 1
                    procesarDoc(view raw, rn, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
                    rn = 0
                    linea = 0
                    tragar = false
                }
                raw[rn] = b
                rn += 1
            }
        }
    }
    when estado == 0 && g[X_ABORT] == 0 {
        when esSeparador(view raw, linea, rn) {
            g[C_SEPARADORES] = g[C_SEPARADORES] + 1
            rn = linea
        }
        when rn > 0 {
            procesarDoc(view raw, rn, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
        }
    }
    hold c = fileClose(f)
    when estado != 0 {
        g[C_ILEG] = g[C_ILEG] + 1
        give estado
    }
    give c
}

// Registra una línea JSONL inválida (los 24 primeros con su línea y motivo).
flow registrarInvalida(g: edit List of[Int], lineno: Int, motivo: Int) {
    g[C_JINV] = g[C_JINV] + 1
    hold q = g[J_NLOG]
    when q < 24 {
        g[J_LOG + q] = (g[C_JARCH] << 40) | (motivo << 32) | lineno
        g[J_NLOG] = q + 1
    }
}

// Una línea JSONL completa en raw[0..rn): la convierte y la procesa.
flow procesarLineaJson(raw: view List of[Int], rn: Int, largo: Bool, lineno: Int, jd: edit List of[Int], dec: edit List of[Int], nor: edit List of[Int], k: edit List of[Int], g: edit List of[Int], ex: edit List of[Int], sigs: edit List of[Int], bandas: edit List of[Int], meta: edit List of[Int], fe: view File, fv: view File, fp: view File) {
    // Línea en blanco (solo espacios, tab, CR): se ignora sin contarla.
    change blanca = true
    when !largo {
        each q among 0..rn {
            hold c = raw[q]
            when c != 32 && c != 9 && c != 13 && c != 10 { blanca = false }
        }
    } otherwise {
        blanca = false
    }
    when blanca { give }
    g[C_JLEIDAS] = g[C_JLEIDAS] + 1
    when largo {
        registrarInvalida(edit g, lineno, 4)
        give
    }
    change primera = 0
    when lineno == 1 { primera = 1 }
    hold dl = convertirLinea(raw, rn, edit jd, edit g, primera)
    when dl < 0 {
        hold mo = g[J_MOTIVO]
        registrarInvalida(edit g, lineno, mo)
        give
    }
    g[C_JTU] = g[C_JTU] + g[J_T_TU]
    g[C_JENCA] = g[C_JENCA] + g[J_T_EN]
    g[C_JSYS] = g[C_JSYS] + g[J_T_SY]
    when dl == 0 {
        g[C_JVACIAS] = g[C_JVACIAS] + 1
        give
    }
    g[C_JCONV] = g[C_JCONV] + 1
    procesarDoc(view jd, dl, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
}

// Archivo JSONL: cada línea (hasta el salto de línea) es una conversación = un documento.
flow procesarJsonl(ruta: view Text, blk: edit List of[Int], raw: edit List of[Int], dec: edit List of[Int], nor: edit List of[Int], k: edit List of[Int], g: edit List of[Int], ex: edit List of[Int], sigs: edit List of[Int], bandas: edit List of[Int], meta: edit List of[Int], fe: view File, fv: view File, fp: view File, jd: edit List of[Int]) => Int {
    hold f = fileOpen(ruta, 1)
    when fileStatus(f) != 0 {
        hold st = fileStatus(f)
        fileClose(f)
        g[C_ILEG] = g[C_ILEG] + 1
        give st
    }
    g[C_ARCH] = g[C_ARCH] + 1
    g[C_JARCH] = g[C_JARCH] + 1
    g[X_IDX] = 0
    change rn = 0
    change lineno = 0
    change largo = false
    change estado = 0
    hold lim = raw.length - 8
    during g[X_ABORT] == 0 {
        hold got = fileRead(f, blk, BLOQUE)
        when got < 0 {
            estado = got
            leave
        }
        when got == 0 { leave }
        g[C_ENTRADA] = g[C_ENTRADA] + got
        each j among 0..got {
            hold b = blk[j]
            when b == 10 {
                lineno += 1
                procesarLineaJson(view raw, rn, largo, lineno, edit jd, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
                rn = 0
                largo = false
            } otherwise when rn < lim {
                raw[rn] = b
                rn += 1
            } otherwise {
                largo = true
            }
        }
    }
    when estado == 0 && g[X_ABORT] == 0 && (rn > 0 || largo) {
        lineno += 1
        procesarLineaJson(view raw, rn, largo, lineno, edit jd, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
    }
    hold c = fileClose(f)
    when estado != 0 {
        g[C_ILEG] = g[C_ILEG] + 1
        give estado
    }
    give c
}

// Recorre la lista de archivos: cada línea "T|D <TAB> ruta <TAB> id".
expose flow recorrerLista(lista: view Text, blk: edit List of[Int], raw: edit List of[Int], dec: edit List of[Int], nor: edit List of[Int], k: edit List of[Int], g: edit List of[Int], ex: edit List of[Int], sigs: edit List of[Int], bandas: edit List of[Int], meta: edit List of[Int], fe: view File, fv: view File, fp: view File, jd: edit List of[Int]) => Int {
    change pb: List of[Int] = List[]
    change i = 0
    hold total = lista.byteLength
    during i < total && g[X_ABORT] == 0 {
        // Una línea: tipo, tab, ruta, tab, id.
        change fin = i
        during fin < total && lista@byteAt(fin) != 10 {
            fin += 1
        }
        change a = i
        i = fin + 1
        change linea = fin
        during linea > a && lista@byteAt(linea - 1) == 13 {
            linea -= 1
        }
        when linea - a < 4 { proceed }
        hold tipoB = lista@byteAt(a)
        change t1 = a
        during t1 < linea && lista@byteAt(t1) != 9 {
            t1 += 1
        }
        change t2 = t1 + 1
        during t2 < linea && lista@byteAt(t2) != 9 {
            t2 += 1
        }
        when t1 >= linea || t2 >= linea { proceed }
        // Ruta para abrir.
        change np = 0
        change q = t1 + 1
        during q < t2 {
            poner(edit pb, np, lista@byteAt(q))
            np += 1
            q += 1
        }
        // Identidad estable del archivo (hash de los bytes del id).
        change h = 0xcbf29ce484222325
        change r = t2 + 1
        during r < linea {
            h = (h ^ lista@byteAt(r)) *% 0x100000001b3
            r += 1
        }
        g[X_IDH] = mezclar(h)
        g[X_TIPO] = 0
        when tipoB == 68 { g[X_TIPO] = 1 }
        // ¿La ruta termina en .jsonl (sin distinguir mayúsculas)?
        g[X_JSON] = 0
        when t2 - t1 - 1 >= 6 {
            hold q0 = t2 - 6
            when lista@byteAt(q0) == 46 && (lista@byteAt(q0 + 1) | 32) == 106 && (lista@byteAt(q0 + 2) | 32) == 115 && (lista@byteAt(q0 + 3) | 32) == 111 && (lista@byteAt(q0 + 4) | 32) == 110 && (lista@byteAt(q0 + 5) | 32) == 108 {
                g[X_JSON] = 1
            }
        }
        choose textFromBytes(pb, np) {
            Ok(rt): {
                change st = 0
                when g[X_JSON] == 1 {
                    st = procesarJsonl(view rt, edit blk, edit raw, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp, edit jd)
                } otherwise {
                    st = procesarArchivo(view rt, edit blk, edit raw, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp)
                }
                when st != 0 {
                    printError("aviso: no se pudo leer un archivo de la lista")
                }
            },
            Err(c): {
                g[C_ILEG] = g[C_ILEG] + 1
                printError("aviso: ruta no válida en la lista")
            },
        }
    }
    give g[X_ABORT]
}
