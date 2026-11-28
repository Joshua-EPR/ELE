// Duplicados: exactos (hash de 64 bits, tabla de direccionamiento abierto) y
// casi exactos (MinHash de una permutación con 32 casillas sobre 5-gramas de
// palabras + LSH de 8 bandas de 4 casillas de 16 bits). Cada 5-grama actualiza
// una sola casilla (la elige el hash), así que el coste no depende de las 32.
take util

expose fixed FNV_BASE: Int = 0xcbf29ce484222325
expose fixed FNV_PRIMO: Int = 0x100000001b3

// Hash de 64 bits del documento normalizado (FNV-1a + mezcla final).
expose flow hashDoc(s: view List of[Int], n: Int) => Int {
    change h = FNV_BASE
    change i = 0
    during i < n {
        h = (h ^ s[i]) *% FNV_PRIMO
        i += 1
    }
    give mezclar(h ^ n)
}

// Hash de una identidad de texto (bytes de un Text).
expose flow hashTexto(t: view Text) => Int {
    change h = FNV_BASE
    each i among 0..t.byteLength {
        h = (h ^ t@byteAt(i)) *% FNV_PRIMO
    }
    give mezclar(h)
}

// ---- Duplicados exactos ----
// La tabla `t` tiene tamaño potencia de dos; 0 = hueco libre.
expose flow exactoExiste(t: view List of[Int], h0: Int) => Bool {
    change h = h0
    when h == 0 { h = 1 }
    hold mascara = t.length - 1
    change s = h & mascara
    during t[s] != 0 {
        when t[s] == h { give true }
        s = (s + 1) & mascara
    }
    give false
}

expose flow exactoInsertar(t: edit List of[Int], h0: Int) {
    change h = h0
    when h == 0 { h = 1 }
    hold mascara = t.length - 1
    change s = h & mascara
    during t[s] != 0 {
        when t[s] == h { give }
        s = (s + 1) & mascara
    }
    t[s] = h
}

// ---- MinHash ----
// Símbolo de palabra de un byte no ASCII en la posición i (0 = separador).
// Separa los bloques E2 xx xx (puntuación general) y C2 xx (símbolos latinos);
// pasa a minúscula las letras latinas con tilde (C3 80..9E salvo C3 97).
flow simboloNoAscii(s: view List of[Int], i: Int) => Int {
    hold b = s[i]
    when b == 0xE2 || b == 0xC2 { give 0 }
    change previo = 0
    when i > 0 { previo = s[i - 1] }
    when previo == 0xC2 { give 0 }
    when b <= 0xBF {
        when previo == 0xE2 { give 0 }
        when i > 1 && previo >= 0x80 && previo <= 0xBF && s[i - 2] == 0xE2 { give 0 }
        when previo == 0xC3 && b <= 0x9E && b != 0x97 { give b + 32 }
    }
    give b
}

// Cierra una palabra: entra en el anillo de 5 y, con 5 o más, da un 5-grama.
flow cerrarPalabra(k: edit List of[Int], wh: Int, nw: Int) {
    k[K_ANILLO + (nw % 5)] = mezclar(wh)
    when nw + 1 >= 5 {
        minimos(edit k, 5, nw + 1)
    }
}

// Calcula en k[K_SIG..K_SIG+8) la firma de 32 casillas de 16 bits.
// Casilla vacía = 0xFFFF (los documentos cortos dejan casillas vacías).
expose flow firma(s: view List of[Int], n: Int, k: edit List of[Int]) {
    each j among 0..32 {
        k[K_MINS + j] = 0x7FFFFFFFFFFFFFFF
    }
    change nw = 0
    change wh = FNV_BASE
    change enPalabra = false
    change i = 0
    during i < n {
        hold b = s[i]
        change c = 0
        when b < 0x80 {
            c = k[K_TOK + b]
        } otherwise {
            c = simboloNoAscii(s, i)
        }
        when c > 0 {
            wh = (wh ^ c) *% FNV_PRIMO
            enPalabra = true
        } otherwise when enPalabra {
            cerrarPalabra(edit k, wh, nw)
            nw += 1
            wh = FNV_BASE
            enPalabra = false
        }
        i += 1
    }
    when enPalabra {
        cerrarPalabra(edit k, wh, nw)
        nw += 1
    }
    when nw > 0 && nw < 5 {
        minimos(edit k, nw, nw)
    }
    // Empaqueta las 32 casillas (16 bits cada una) en 8 palabras.
    each w among 0..8 {
        change v = 0
        each j among 0..4 {
            hold m = k[K_MINS + w * 4 + j]
            change e = 65535
            when m != 0x7FFFFFFFFFFFFFFF {
                e = ((m >> 6) & 0xFFFF) % 65535
            }
            v = v | (e << (j * 16))
        }
        k[K_SIG + w] = v
    }
}

// Un shingle de `cuantas` palabras del anillo (las últimas, hasta la nº nw):
// su hash elige la casilla (5 bits bajos) y su valor (el resto).
flow minimos(k: edit List of[Int], cuantas: Int, nw: Int) {
    change sh = 0
    each j among 0..cuantas {
        hold pos = (nw - cuantas + j) % 5
        sh = (sh *% 0x9E3779B97F4A7C15) +% k[K_ANILLO + pos]
    }
    hold h = mezclar(sh)
    hold casilla = K_MINS + (h & 31)
    hold v = h >> 5
    when v < k[casilla] { k[casilla] = v }
}

// Compara dos firmas: devuelve iguales * 64 + casillas con algún dato.
// Una casilla vacía en ambas no cuenta; vacía en una sola cuenta como distinta.
flow comparar(sigs: view List of[Int], id: Int, k: view List of[Int]) => Int {
    change iguales = 0
    change con = 0
    each w among 0..8 {
        hold a = sigs[id * 8 + w]
        hold b = k[K_SIG + w]
        each j among 0..4 {
            hold ea = (a >> (j * 16)) & 0xFFFF
            hold eb = (b >> (j * 16)) & 0xFFFF
            when ea == eb {
                when ea != 0xFFFF {
                    iguales += 1
                    con += 1
                }
            } otherwise {
                con += 1
            }
        }
    }
    give iguales * 64 + con
}

flow claveBanda(k: view List of[Int], j: Int) => Int {
    give mezclar(k[K_SIG + j] ^ ((j + 1) *% 0x9E3779B97F4A7C15))
}

// ¿Hay en la tabla un documento anterior con similitud >= sim por ciento?
// Las bandas sin ningún dato (todas las casillas vacías) no se consultan.
expose flow casiExiste(bandas: view List of[Int], sigs: view List of[Int], k: view List of[Int], sim: Int) => Bool {
    hold mascara = bandas.length - 1
    each j among 0..8 {
        when k[K_SIG + j] == 0 - 1 { proceed }
        hold clave = claveBanda(k, j)
        hold chk = clave >> 24
        change s = clave & mascara
        during bandas[s] != 0 {
            when (bandas[s] >> 24) == chk {
                hold id = (bandas[s] & 0xFFFFFF) - 1
                hold r = comparar(sigs, id, k)
                hold den = r % 64
                when den > 0 && (r / 64) * 100 >= sim * den { give true }
            }
            s = (s + 1) & mascara
        }
    }
    give false
}

// Registra el documento (id = nº de firmas ya guardadas) en sigs y bandas.
expose flow casiInsertar(bandas: edit List of[Int], sigs: edit List of[Int], k: view List of[Int]) {
    hold id = sigs.length / 8
    each w among 0..8 {
        sigs@push(k[K_SIG + w])
    }
    hold mascara = bandas.length - 1
    each j among 0..8 {
        when k[K_SIG + j] == 0 - 1 { proceed }
        hold clave = claveBanda(k, j)
        hold chk = clave >> 24
        change s = clave & mascara
        change puesto = false
        during !puesto {
            when bandas[s] == 0 {
                bandas[s] = (chk << 24) | (id + 1)
                puesto = true
            } otherwise when (bandas[s] >> 24) == chk {
                puesto = true
            } otherwise {
                s = (s + 1) & mascara
            }
        }
    }
}
