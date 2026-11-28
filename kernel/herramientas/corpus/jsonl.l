// Conversaciones en JSONL -> documento de diálogo (Fase 4, hito 23).
//
// Una línea JSON es una conversación. Formatos (por claves de primer nivel):
//   {"messages": [{"role": R, "content": C}, ...]}
//   {"conversations": [{"from": R, "value": C}, ...]}
//   {"prompt"|"instruction"|"input": P, "response"|"output"|"completion": R}
// Roles: user/human/usuario -> "TÚ"; assistant/gpt/bot/model/enca -> "ENCA";
// system -> se omite (se cuenta). Cualquier otro rol o error -> inválida.
// El documento: un turno por línea ("TÚ: texto"), saltos y espacios repetidos
// dentro del turno reducidos a un espacio; los turnos vacíos se omiten.
//
// El estado del analizador vive en la lista G (J_*). Todo se decodifica en
// la lista de bytes `d`; el contenido de un turno se decodifica 6 bytes por
// delante de su inicio para poder poner delante el prefijo ("TÚ: " o "ENCA: ").
take util
take texto

// Claves (ids): 0 messages, 1 conversations, 2 prompt, 3 instruction,
// 4 input, 5 response, 6 output, 7 completion, 8 role, 9 from, 10 content,
// 11 value.

flow jsFallo(g: edit List of[Int], motivo: Int) {
    when g[J_ERR] == 0 {
        g[J_ERR] = 1
        g[J_MOTIVO] = motivo
    }
}

flow jsAsegurar(d: edit List of[Int], n: Int) {
    during d.length < n {
        d@push(0)
    }
}

// Siguiente byte no blanco (sin consumirlo) o -1 al final de la línea.
flow jsActual(s: view List of[Int], g: edit List of[Int]) => Int {
    change p = g[J_POS]
    hold n = g[J_LEN]
    during p < n && (s[p] == 32 || s[p] == 9 || s[p] == 10 || s[p] == 13) {
        p += 1
    }
    g[J_POS] = p
    when p >= n { give 0 - 1 }
    give s[p]
}

flow hexVal(c: Int) => Int {
    when c >= 48 && c <= 57 { give c - 48 }
    when c >= 97 && c <= 102 { give c - 87 }
    when c >= 65 && c <= 70 { give c - 55 }
    give 0 - 1
}

// Cuatro dígitos hexadecimales desde s[p], o -1.
flow jsHex4(s: view List of[Int], p: Int, n: Int) => Int {
    when p + 4 > n { give 0 - 1 }
    change v = 0
    each j among 0..4 {
        hold h = hexVal(s[p + j])
        when h < 0 { give 0 - 1 }
        v = v * 16 + h
    }
    give v
}

// Escribe un punto de código en UTF-8 desde `pos`; devuelve la nueva posición.
flow jsPonerCp(d: edit List of[Int], pos: Int, cp: Int) => Int {
    when cp < 0x80 {
        poner(edit d, pos, cp)
        give pos + 1
    }
    when cp < 0x800 {
        poner(edit d, pos, 0xC0 | (cp >> 6))
        poner(edit d, pos + 1, 0x80 | (cp & 63))
        give pos + 2
    }
    when cp < 0x10000 {
        poner(edit d, pos, 0xE0 | (cp >> 12))
        poner(edit d, pos + 1, 0x80 | ((cp >> 6) & 63))
        poner(edit d, pos + 2, 0x80 | (cp & 63))
        give pos + 3
    }
    poner(edit d, pos, 0xF0 | (cp >> 18))
    poner(edit d, pos + 1, 0x80 | ((cp >> 12) & 63))
    poner(edit d, pos + 2, 0x80 | ((cp >> 6) & 63))
    poner(edit d, pos + 3, 0x80 | (cp & 63))
    give pos + 4
}

// Cadena JSON: s[J_POS] es la comilla de apertura. Decodifica a d desde `base`.
// Con colapsar = 1 los blancos ASCII (espacio, tab, CR, LF) se reducen a un
// espacio y se recortan por los dos extremos. Devuelve los bytes escritos o -1.
flow jsCadena(s: view List of[Int], g: edit List of[Int], d: edit List of[Int], base: Int, colapsar: Int) => Int {
    hold n = g[J_LEN]
    change p = g[J_POS] + 1
    change w = base
    change pend = 0
    jsAsegurar(edit d, base)
    during p < n {
        hold c = s[p]
        when c == 34 {
            g[J_POS] = p + 1
            give w - base
        }
        when c < 32 {
            jsFallo(edit g, 1)
            give 0 - 1
        }
        change cp = c
        change avance = 1
        change esc = 0
        when c == 92 {
            esc = 1
            when p + 1 >= n {
                jsFallo(edit g, 1)
                give 0 - 1
            }
            hold e = s[p + 1]
            avance = 2
            when e == 34 || e == 92 || e == 47 {
                cp = e
            } otherwise when e == 98 {
                cp = 8
            } otherwise when e == 102 {
                cp = 12
            } otherwise when e == 110 {
                cp = 10
            } otherwise when e == 114 {
                cp = 13
            } otherwise when e == 116 {
                cp = 9
            } otherwise when e == 117 {
                hold v = jsHex4(s, p + 2, n)
                when v < 0 || (v >= 0xDC00 && v <= 0xDFFF) {
                    jsFallo(edit g, 1)
                    give 0 - 1
                }
                when v >= 0xD800 && v <= 0xDBFF {
                    // Par sustituto: debe seguir otro \uXXXX bajo.
                    when p + 7 >= n || s[p + 6] != 92 || s[p + 7] != 117 {
                        jsFallo(edit g, 1)
                        give 0 - 1
                    }
                    hold v2 = jsHex4(s, p + 8, n)
                    when v2 < 0xDC00 || v2 > 0xDFFF {
                        jsFallo(edit g, 1)
                        give 0 - 1
                    }
                    cp = 0x10000 + ((v - 0xD800) << 10) + (v2 - 0xDC00)
                    avance = 12
                } otherwise {
                    cp = v
                    avance = 6
                }
            } otherwise {
                jsFallo(edit g, 1)
                give 0 - 1
            }
        }
        p += avance
        when colapsar == 1 && (cp == 32 || cp == 9 || cp == 10 || cp == 13) {
            pend = 1
        } otherwise {
            when pend == 1 && w > base {
                poner(edit d, w, 32)
                w += 1
            }
            pend = 0
            when esc == 0 && c >= 0x80 {
                poner(edit d, w, c)
                w += 1
            } otherwise {
                w = jsPonerCp(edit d, w, cp)
            }
        }
    }
    jsFallo(edit g, 1)
    give 0 - 1
}

flow jsLiteral(s: view List of[Int], g: edit List of[Int], t: Text) => Int {
    hold p = g[J_POS]
    hold l = t.byteLength
    when p + l > g[J_LEN] {
        jsFallo(edit g, 1)
        give 0 - 1
    }
    each i among 0..l {
        when s[p + i] != t@byteAt(i) {
            jsFallo(edit g, 1)
            give 0 - 1
        }
    }
    g[J_POS] = p + l
    give 0
}

// Dígitos desde p; devuelve la posición siguiente.
flow jsDigitos(s: view List of[Int], p: Int, n: Int) => Int {
    change q = p
    during q < n && s[q] >= 48 && s[q] <= 57 {
        q += 1
    }
    give q
}

// Número JSON estricto: -?(0|[1-9]d*)(.d+)?([eE][+-]?d+)?
flow jsNumero(s: view List of[Int], g: edit List of[Int]) => Int {
    hold n = g[J_LEN]
    change p = g[J_POS]
    when s[p] == 45 { p += 1 }
    when p >= n {
        jsFallo(edit g, 1)
        give 0 - 1
    }
    when s[p] == 48 {
        p += 1
    } otherwise when s[p] >= 49 && s[p] <= 57 {
        p = jsDigitos(s, p, n)
    } otherwise {
        jsFallo(edit g, 1)
        give 0 - 1
    }
    when p < n && s[p] == 46 {
        hold q = jsDigitos(s, p + 1, n)
        when q == p + 1 {
            jsFallo(edit g, 1)
            give 0 - 1
        }
        p = q
    }
    when p < n && (s[p] == 101 || s[p] == 69) {
        change q2 = p + 1
        when q2 < n && (s[q2] == 43 || s[q2] == 45) { q2 += 1 }
        hold q3 = jsDigitos(s, q2, n)
        when q3 == q2 {
            jsFallo(edit g, 1)
            give 0 - 1
        }
        p = q3
    }
    g[J_POS] = p
    give 0
}

// Valida y salta un valor cualquiera. Las cadenas se decodifican en la zona
// de trabajo (desde J_ALTO) y se descartan.
flow jsSaltar(s: view List of[Int], g: edit List of[Int], d: edit List of[Int], prof: Int) => Int {
    when prof > 64 {
        jsFallo(edit g, 1)
        give 0 - 1
    }
    hold c = jsActual(s, edit g)
    when c < 0 {
        jsFallo(edit g, 1)
        give 0 - 1
    }
    when c == 34 {
        hold b_l = g[J_ALTO]
        hold l = jsCadena(s, edit g, edit d, b_l, 0)
        when l < 0 { give 0 - 1 }
        give 0
    }
    when c == 123 || c == 91 {
        change cierre = 125
        when c == 91 { cierre = 93 }
        g[J_POS] = g[J_POS] + 1
        when jsActual(s, edit g) == cierre {
            g[J_POS] = g[J_POS] + 1
            give 0
        }
        during g[J_ERR] == 0 {
            when c == 123 {
                when jsActual(s, edit g) != 34 {
                    jsFallo(edit g, 1)
                    give 0 - 1
                }
                hold b_lk = g[J_ALTO]
                hold lk = jsCadena(s, edit g, edit d, b_lk, 0)
                when lk < 0 { give 0 - 1 }
                when jsActual(s, edit g) != 58 {
                    jsFallo(edit g, 1)
                    give 0 - 1
                }
                g[J_POS] = g[J_POS] + 1
            }
            hold r = jsSaltar(s, edit g, edit d, prof + 1)
            when r < 0 { give 0 - 1 }
            hold sep = jsActual(s, edit g)
            when sep == 44 {
                g[J_POS] = g[J_POS] + 1
                proceed
            }
            when sep == cierre {
                g[J_POS] = g[J_POS] + 1
                give 0
            }
            jsFallo(edit g, 1)
            give 0 - 1
        }
        give 0 - 1
    }
    when c == 116 { give jsLiteral(s, edit g, "true") }
    when c == 102 { give jsLiteral(s, edit g, "false") }
    when c == 110 { give jsLiteral(s, edit g, "null") }
    when c == 45 || (c >= 48 && c <= 57) { give jsNumero(s, edit g) }
    jsFallo(edit g, 1)
    give 0 - 1
}

// ¿d[base..base+len) es el texto t? Con minusculas = 1 se pliegan A-Z.
flow jsIgual(d: view List of[Int], base: Int, len: Int, t: Text, minusculas: Int) => Bool {
    when len != t.byteLength { give false }
    each i among 0..len {
        change b = d[base + i]
        when minusculas == 1 && b >= 65 && b <= 90 { b = b + 32 }
        when b != t@byteAt(i) { give false }
    }
    give true
}

flow jsClaveId(d: view List of[Int], base: Int, len: Int) => Int {
    when jsIgual(d, base, len, "messages", 0) { give 0 }
    when jsIgual(d, base, len, "conversations", 0) { give 1 }
    when jsIgual(d, base, len, "prompt", 0) { give 2 }
    when jsIgual(d, base, len, "instruction", 0) { give 3 }
    when jsIgual(d, base, len, "input", 0) { give 4 }
    when jsIgual(d, base, len, "response", 0) { give 5 }
    when jsIgual(d, base, len, "output", 0) { give 6 }
    when jsIgual(d, base, len, "completion", 0) { give 7 }
    when jsIgual(d, base, len, "role", 0) { give 8 }
    when jsIgual(d, base, len, "from", 0) { give 9 }
    when jsIgual(d, base, len, "content", 0) { give 10 }
    when jsIgual(d, base, len, "value", 0) { give 11 }
    give 0 - 1
}

// 1 = TÚ, 2 = ENCA, 3 = system, 0 = desconocido.
flow jsRol(d: view List of[Int], base: Int, len: Int) => Int {
    when jsIgual(d, base, len, "user", 1) || jsIgual(d, base, len, "human", 1) || jsIgual(d, base, len, "usuario", 1) { give 1 }
    when jsIgual(d, base, len, "assistant", 1) || jsIgual(d, base, len, "gpt", 1) || jsIgual(d, base, len, "bot", 1) || jsIgual(d, base, len, "model", 1) || jsIgual(d, base, len, "enca", 1) { give 2 }
    when jsIgual(d, base, len, "system", 1) { give 3 }
    give 0
}

// Cierra un turno cuyo contenido está en d[J_N+6 ..+clen): pone el prefijo,
// lo acerca si hace falta, añade el salto y adelanta J_N.
flow jsCerrarTurno(d: edit List of[Int], g: edit List of[Int], rol: Int, clen: Int) {
    hold ini = g[J_N]
    when rol == 3 {
        g[J_T_SY] = g[J_T_SY] + 1
        give
    }
    when clen <= 0 { give }
    change w = ini
    when rol == 1 {
        d[ini] = 0x54
        d[ini + 1] = 0xC3
        d[ini + 2] = 0x9A
        d[ini + 3] = 0x3A
        d[ini + 4] = 0x20
        each i among 0..clen {
            d[ini + 5 + i] = d[ini + 6 + i]
        }
        w = ini + 5 + clen
        g[J_T_TU] = g[J_T_TU] + 1
    } otherwise {
        d[ini] = 0x45
        d[ini + 1] = 0x4E
        d[ini + 2] = 0x43
        d[ini + 3] = 0x41
        d[ini + 4] = 0x3A
        d[ini + 5] = 0x20
        w = ini + 6 + clen
        g[J_T_EN] = g[J_T_EN] + 1
    }
    poner(edit d, w, 10)
    g[J_N] = w + 1
}

// Una pasada reinicia lo ya escrito por una clave repetida (gana la última).
flow jsReiniciar(g: edit List of[Int], tipo: Int) {
    g[J_N] = g[J_INI]
    g[J_ALTO] = g[J_INI]
    when tipo == 1 || tipo == 2 {
        g[J_T_TU] = 0
        g[J_T_EN] = 0
        g[J_T_SY] = 0
    } otherwise when tipo == 3 {
        g[J_T_TU] = 0
    } otherwise when tipo == 4 {
        g[J_T_EN] = 0
    }
}

// Un mensaje {role/from, content/value}; s[J_POS] está tras la llave.
flow jsMensaje(s: view List of[Int], g: edit List of[Int], d: edit List of[Int], idRol: Int, idCont: Int) => Int {
    hold ini = g[J_N]
    g[J_ALTO] = ini
    change rol = 0 - 1
    change clen = 0 - 1
    during g[J_ERR] == 0 {
        when jsActual(s, edit g) != 34 {
            jsFallo(edit g, 3)
            give 0 - 1
        }
        hold b_lk = g[J_ALTO]
        hold lk = jsCadena(s, edit g, edit d, b_lk, 0)
        when lk < 0 { give 0 - 1 }
        hold id = jsClaveId(view d, g[J_ALTO], lk)
        when jsActual(s, edit g) != 58 {
            jsFallo(edit g, 1)
            give 0 - 1
        }
        g[J_POS] = g[J_POS] + 1
        when id == idRol {
            when jsActual(s, edit g) != 34 {
                jsFallo(edit g, 3)
                give 0 - 1
            }
            hold b_lr = g[J_ALTO]
            hold lr = jsCadena(s, edit g, edit d, b_lr, 0)
            when lr < 0 { give 0 - 1 }
            rol = jsRol(view d, g[J_ALTO], lr)
            when rol == 0 {
                jsFallo(edit g, 2)
                give 0 - 1
            }
        } otherwise when id == idCont {
            when jsActual(s, edit g) != 34 {
                jsFallo(edit g, 3)
                give 0 - 1
            }
            hold base = ini + 6
            clen = jsCadena(s, edit g, edit d, base, 1)
            when clen < 0 { give 0 - 1 }
            g[J_ALTO] = base + clen
        } otherwise {
            hold r = jsSaltar(s, edit g, edit d, 2)
            when r < 0 { give 0 - 1 }
        }
        hold sep = jsActual(s, edit g)
        when sep == 44 {
            g[J_POS] = g[J_POS] + 1
            proceed
        }
        when sep == 125 {
            g[J_POS] = g[J_POS] + 1
            when rol < 0 || clen < 0 {
                jsFallo(edit g, 3)
                give 0 - 1
            }
            jsCerrarTurno(edit d, edit g, rol, clen)
            g[J_ALTO] = g[J_N]
            give 0
        }
        jsFallo(edit g, 1)
        give 0 - 1
    }
    give 0 - 1
}

// Valor de "messages"/"conversations": array de mensajes.
flow jsTurnos(s: view List of[Int], g: edit List of[Int], d: edit List of[Int], tipo: Int) => Int {
    jsReiniciar(edit g, tipo)
    hold idRol = 8 + (tipo - 1)
    hold idCont = 10 + (tipo - 1)
    when jsActual(s, edit g) != 91 {
        jsFallo(edit g, 3)
        give 0 - 1
    }
    g[J_POS] = g[J_POS] + 1
    when jsActual(s, edit g) == 93 {
        g[J_POS] = g[J_POS] + 1
        give 0
    }
    during g[J_ERR] == 0 {
        when jsActual(s, edit g) != 123 {
            jsFallo(edit g, 3)
            give 0 - 1
        }
        g[J_POS] = g[J_POS] + 1
        hold r = jsMensaje(s, edit g, edit d, idRol, idCont)
        when r < 0 { give 0 - 1 }
        hold sep = jsActual(s, edit g)
        when sep == 44 {
            g[J_POS] = g[J_POS] + 1
            proceed
        }
        when sep == 93 {
            g[J_POS] = g[J_POS] + 1
            give 0
        }
        jsFallo(edit g, 1)
        give 0 - 1
    }
    give 0 - 1
}

// Valor de la clave de pregunta (tipo 3, TÚ) o de respuesta (tipo 4, ENCA).
flow jsPar(s: view List of[Int], g: edit List of[Int], d: edit List of[Int], tipo: Int) => Int {
    jsReiniciar(edit g, tipo)
    when jsActual(s, edit g) != 34 {
        jsFallo(edit g, 3)
        give 0 - 1
    }
    hold ini = g[J_N]
    hold clen = jsCadena(s, edit g, edit d, ini + 6, 1)
    when clen < 0 { give 0 - 1 }
    change rol = 1
    when tipo == 4 { rol = 2 }
    jsCerrarTurno(edit d, edit g, rol, clen)
    g[J_ALTO] = g[J_N]
    give 0
}

// Recorre el objeto de primer nivel. tipo 0: anota las claves vistas;
// 1 messages; 2 conversations; 3 y 4: la cadena de pregunta/respuesta.
// `sel` es el id de la clave que se extrae.
flow jsTop(s: view List of[Int], g: edit List of[Int], d: edit List of[Int], tipo: Int, sel: Int) => Int {
    when jsActual(s, edit g) != 123 {
        jsFallo(edit g, 3)
        give 0 - 1
    }
    g[J_POS] = g[J_POS] + 1
    when jsActual(s, edit g) == 125 {
        g[J_POS] = g[J_POS] + 1
        give 0
    }
    during g[J_ERR] == 0 {
        when jsActual(s, edit g) != 34 {
            jsFallo(edit g, 1)
            give 0 - 1
        }
        hold b_lk = g[J_ALTO]
        hold lk = jsCadena(s, edit g, edit d, b_lk, 0)
        when lk < 0 { give 0 - 1 }
        hold id = jsClaveId(view d, g[J_ALTO], lk)
        when jsActual(s, edit g) != 58 {
            jsFallo(edit g, 1)
            give 0 - 1
        }
        g[J_POS] = g[J_POS] + 1
        change r = 0
        when tipo == 0 {
            when id >= 0 && id <= 7 {
                g[J_VISTAS] = g[J_VISTAS] | (1 << id)
            }
            r = jsSaltar(s, edit g, edit d, 1)
        } otherwise when id == sel {
            when tipo == 1 || tipo == 2 {
                r = jsTurnos(s, edit g, edit d, tipo)
            } otherwise {
                r = jsPar(s, edit g, edit d, tipo)
            }
        } otherwise {
            r = jsSaltar(s, edit g, edit d, 1)
        }
        when r < 0 { give 0 - 1 }
        hold sep = jsActual(s, edit g)
        when sep == 44 {
            g[J_POS] = g[J_POS] + 1
            proceed
        }
        when sep == 125 {
            g[J_POS] = g[J_POS] + 1
            give 0
        }
        jsFallo(edit g, 1)
        give 0 - 1
    }
    give 0 - 1
}

// Primera clave presente de un grupo (por prioridad), o -1.
flow jsElegir(v: Int, a: Int, b: Int, c: Int) => Int {
    when (v & (1 << a)) != 0 { give a }
    when (v & (1 << b)) != 0 { give b }
    when (v & (1 << c)) != 0 { give c }
    give 0 - 1
}

// Convierte la línea s[0..n) en el documento d[0..m). Devuelve m (puede ser 0
// si no hubo turnos) o -1 si es inválida (motivo en J_MOTIVO). Deja en
// J_T_TU / J_T_EN / J_T_SY los turnos de esta conversación.
expose flow convertirLinea(s: view List of[Int], n: Int, d: edit List of[Int], g: edit List of[Int], primera: Int) => Int {
    g[J_LEN] = n
    g[J_ERR] = 0
    g[J_MOTIVO] = 0
    g[J_N] = 0
    g[J_ALTO] = 0
    g[J_INI] = 0
    g[J_VISTAS] = 0
    g[J_T_TU] = 0
    g[J_T_EN] = 0
    g[J_T_SY] = 0
    change ini = 0
    when primera == 1 && n >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF {
        ini = 3
    }
    when !esUtf8(s, n) {
        g[J_MOTIVO] = 5
        give 0 - 1
    }
    // Pasada 0: validar todo y ver qué claves hay.
    g[J_POS] = ini
    when jsTop(s, edit g, edit d, 0, 0 - 1) < 0 { give 0 - 1 }
    when jsActual(s, edit g) >= 0 {
        jsFallo(edit g, 1)
        give 0 - 1
    }
    hold v = g[J_VISTAS]
    when (v & 1) != 0 {
        g[J_POS] = ini
        when jsTop(s, edit g, edit d, 1, 0) < 0 { give 0 - 1 }
        give g[J_N]
    }
    when (v & 2) != 0 {
        g[J_POS] = ini
        when jsTop(s, edit g, edit d, 2, 1) < 0 { give 0 - 1 }
        give g[J_N]
    }
    hold cp = jsElegir(v, 2, 3, 4)
    hold cr = jsElegir(v, 5, 6, 7)
    when cp < 0 || cr < 0 {
        jsFallo(edit g, 3)
        give 0 - 1
    }
    g[J_POS] = ini
    when jsTop(s, edit g, edit d, 3, cp) < 0 { give 0 - 1 }
    g[J_INI] = g[J_N]
    g[J_POS] = ini
    when jsTop(s, edit g, edit d, 4, cr) < 0 { give 0 - 1 }
    give g[J_N]
}
