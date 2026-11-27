// Normalización de texto: validación UTF-8, Windows-1252, mojibake,
// limpieza de controles/saltos/espacios y medida de letras.
take util

// Los 32 puntos de código de Windows-1252 para los bytes 0x80..0x9F.
// Los cinco sin asignar (81 8D 8F 90 9D) pasan como controles C1.
flow cp1252Alto() => List of[Int] {
    give List[0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]
}

// ¿Bytes UTF-8 bien formados (sin sobrelargas, sustitutos ni > U+10FFFF)?
expose flow esUtf8(s: view List of[Int], n: Int) => Bool {
    change i = 0
    during i < n {
        hold b = s[i]
        when b < 0x80 {
            i += 1
            during i < n && s[i] < 0x80 {
                i += 1
            }
        } otherwise when b >= 0xC2 && b <= 0xDF {
            when i + 1 >= n { give false }
            when (s[i + 1] & 0xC0) != 0x80 { give false }
            i += 2
        } otherwise when b >= 0xE0 && b <= 0xEF {
            when i + 2 >= n { give false }
            hold c = s[i + 1]
            when (c & 0xC0) != 0x80 || (s[i + 2] & 0xC0) != 0x80 { give false }
            when b == 0xE0 && c < 0xA0 { give false }
            when b == 0xED && c > 0x9F { give false }
            i += 3
        } otherwise when b >= 0xF0 && b <= 0xF4 {
            when i + 3 >= n { give false }
            hold c = s[i + 1]
            when (c & 0xC0) != 0x80 || (s[i + 2] & 0xC0) != 0x80 || (s[i + 3] & 0xC0) != 0x80 { give false }
            when b == 0xF0 && c < 0x90 { give false }
            when b == 0xF4 && c > 0x8F { give false }
            i += 4
        } otherwise {
            give false
        }
    }
    give true
}

// Decodifica el carácter en s[i] (UTF-8 válido): devuelve cp * 8 + longitud.
expose flow cpEn(s: view List of[Int], i: Int) => Int {
    hold b = s[i]
    when b < 0x80 { give b * 8 + 1 }
    when b < 0xE0 { give (((b & 0x1F) << 6) | (s[i + 1] & 0x3F)) * 8 + 2 }
    when b < 0xF0 {
        give (((b & 0x0F) << 12) | ((s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F)) * 8 + 3
    }
    give (((b & 0x07) << 18) | ((s[i + 1] & 0x3F) << 12) | ((s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F)) * 8 + 4
}

// Windows-1252 -> UTF-8. Devuelve los bytes escritos en d.
expose flow desdeCp1252(s: view List of[Int], n: Int, d: edit List of[Int]) => Int {
    hold alto = cp1252Alto()
    change on = 0
    each i among 0..n {
        hold b = s[i]
        when b < 0x80 {
            poner(edit d, on, b)
            on += 1
        } otherwise {
            change cp = b
            when b < 0xA0 { cp = alto[b - 0x80] }
            when cp < 0x800 {
                poner(edit d, on, 0xC0 | (cp >> 6))
                poner(edit d, on + 1, 0x80 | (cp & 63))
                on += 2
            } otherwise {
                poner(edit d, on, 0xE0 | (cp >> 12))
                poner(edit d, on + 1, 0x80 | ((cp >> 6) & 63))
                poner(edit d, on + 2, 0x80 | (cp & 63))
                on += 3
            }
        }
    }
    give on
}

// Byte de Windows-1252 de un punto de código, o -1 si no existe.
flow byteDeCp(cp: Int) => Int {
    when cp < 0x100 { give cp }
    hold alto = cp1252Alto()
    each j among 0..32 {
        when alto[j] == cp { give 0x80 + j }
    }
    give 0 - 1
}

// Cuenta marcas de mojibake ("Ã" + 0x80..0xBF, "Â" + 0xA0..0xBF), UTF-8 válido.
// "Ã" son los bytes C3 83 y "Â" los bytes C3 82: solo se decodifica el
// carácter que los sigue.
expose flow contarMoji(s: view List of[Int], n: Int) => Int {
    change cuenta = 0
    change i = 0
    during i + 3 < n {
        when s[i] == 0xC3 && (s[i + 1] == 0x83 || s[i + 1] == 0x82) {
            change previo = 0xC3
            when s[i + 1] == 0x82 { previo = 0xC2 }
            hold cp = cpEn(s, i + 2) / 8
            when cp >= 0x80 {
                hold by = byteDeCp(cp)
                when previo == 0xC3 && by >= 0x80 && by <= 0xBF { cuenta += 1 }
                when previo == 0xC2 && by >= 0xA0 && by <= 0xBF { cuenta += 1 }
            }
            i += 2
        } otherwise {
            i += 1
        }
    }
    give cuenta
}

// Reinterpreta el texto como Windows-1252 y lo vuelve a leer como UTF-8.
// -1 si algún carácter no tiene byte de origen.
expose flow repararMoji(s: view List of[Int], n: Int, d: edit List of[Int]) => Int {
    change on = 0
    change i = 0
    during i < n {
        hold r = cpEn(s, i)
        hold by = byteDeCp(r / 8)
        when by < 0 { give 0 - 1 }
        poner(edit d, on, by)
        on += 1
        i += r % 8
    }
    give on
}

// Limpieza: BOM, CRLF/CR -> LF, controles fuera, tab -> espacio, sin espacios
// finales, una línea en blanco como máximo, documento recortado y con un \n
// final. Entrada: UTF-8 válido. Deja en G las medidas D_*.
expose flow limpiar(s: view List of[Int], n: Int, o: edit List of[Int], g: edit List of[Int]) => Int {
    // La salida nunca supera n + 1 bytes: se reserva una vez y se escribe directo.
    during o.length < n + 4 {
        o@push(0)
    }
    change on = 0
    change i = 0
    change ctrl = 0
    change ffd = 0
    change extra = 0          // bytes que sobran sobre un byte por carácter
    change hayCr = 0
    change bom = 0
    when n >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF {
        i = 3
        bom = 1
    }
    hold i0 = i
    during i < n {
        hold b = s[i]
        // Camino común: ASCII visible.
        when b > 32 && b < 127 {
            o[on] = b
            on += 1
            i += 1
            proceed
        }
        change largo = 1
        change accion = 1      // 0 quitar, 1 copiar, 2 espacio, 3 salto
        when b < 0x80 {
            when b == 10 {
                accion = 3
            } otherwise when b == 13 {
                accion = 3
                hayCr = 1
                when i + 1 < n && s[i + 1] == 10 { largo = 2 }
            } otherwise when b == 9 || b == 32 {
                accion = 2
            } otherwise when b < 32 || b == 127 {
                accion = 0
                ctrl += 1
            }
        } otherwise {
            change l = 2
            when b >= 0xF0 {
                l = 4
            } otherwise when b >= 0xE0 {
                l = 3
            }
            largo = l
            when l == 2 {
                hold c = s[i + 1]
                when b == 0xC2 && c < 0xA0 {
                    accion = 0
                    ctrl += 1
                } otherwise when b == 0xC2 && c == 0xA0 {
                    accion = 2
                } otherwise when b == 0xC2 && c == 0xAD {
                    accion = 0
                }
            } otherwise when l == 3 {
                hold c = s[i + 1]
                hold d = s[i + 2]
                when b == 0xE2 && c == 0x80 {
                    when d <= 0x8A {
                        accion = 2
                    } otherwise when d <= 0x8F {
                        accion = 0
                    } otherwise when d == 0xA8 || d == 0xA9 {
                        accion = 3
                    } otherwise when d >= 0xAA && d <= 0xAE {
                        accion = 0
                    }
                } otherwise when b == 0xEF && c == 0xBB && d == 0xBF {
                    accion = 0
                } otherwise when b == 0xEF && c == 0xBF && d == 0xBD {
                    ffd += 1
                }
            }
        }
        extra += largo - 1
        when accion == 1 {
            each j among 0..largo {
                o[on] = s[i + j]
                on += 1
            }
        } otherwise when accion == 2 {
            when on > 0 {
                o[on] = 32
                on += 1
            }
        } otherwise when accion == 3 {
            during on > 0 && o[on - 1] == 32 {
                on -= 1
            }
            change k = on
            change c = 0
            during k > 0 && o[k - 1] == 10 && c < 2 {
                k -= 1
                c += 1
            }
            when on > 0 && c < 2 {
                o[on] = 10
                on += 1
            }
        }
        i += largo
    }
    during on > 0 && (o[on - 1] == 10 || o[on - 1] == 32) {
        on -= 1
    }
    when on > 0 {
        o[on] = 10
        on += 1
    }
    g[D_CTRL] = ctrl
    g[D_FFD] = ffd
    g[D_CHARS] = n - i0 - extra
    g[D_CR] = hayCr
    g[D_BOM] = bom
    give on
}

// ¿Es un punto de código "letra" (de cualquier alfabeto)?
expose flow esLetra(cp: Int) => Bool {
    when cp < 0x80 {
        give (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122)
    }
    when cp == 0xAA || cp == 0xB5 || cp == 0xBA { give true }
    when cp >= 0xC0 && cp <= 0x24F { give cp != 0xD7 && cp != 0xF7 }
    when cp >= 0x370 && cp <= 0x1FFF { give true }
    when cp >= 0x3040 && cp <= 0x9FFF { give true }
    when cp >= 0xAC00 && cp <= 0xD7A3 { give true }
    give false
}

// Letras por mil entre los caracteres que no son espacio ni salto. Un solo
// acumulador: la parte alta cuenta letras y la baja los caracteres visibles.
expose flow medirLetras(s: view List of[Int], n: Int, k: view List of[Int]) => Int {
    change acc = 0
    change i = 0
    during i < n {
        hold b = s[i]
        when b < 0x80 {
            acc += k[K_LET + b]
            i += 1
        } otherwise {
            hold r = cpEn(s, i)
            acc += 1
            when esLetra(r / 8) { acc += 4294967296 }
            i += r % 8
        }
    }
    hold total = acc & 0xFFFFFFFF
    when total == 0 { give 0 }
    give (acc >> 32) * 1000 / total
}
