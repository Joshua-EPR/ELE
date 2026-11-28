// Utilidades de la herramienta de corpus: constantes de estado, CRC32C,
// mezcla de 64 bits, buffers elásticos y emisión de texto a listas de bytes.

// ---- Ranuras de la lista de estado G (opciones, contadores, contexto) ----
expose fixed O_MIN: Int = 0          // bytes mínimos de un documento de texto
expose fixed O_MIND: Int = 1         // bytes mínimos de un diálogo
expose fixed O_BASURA: Int = 2       // umbral de no textuales, por mil
expose fixed O_LETRAS: Int = 3       // porcentaje mínimo de letras
expose fixed O_SIM: Int = 4          // similitud de casi duplicado, por ciento
expose fixed O_MAXDOCS: Int = 5      // documentos conservados máximos
expose fixed O_MOJI: Int = 6         // 1 = reparar mojibake
expose fixed O_SEMILLA: Int = 7      // semilla de la partición
expose fixed O_PRUEBA: Int = 8       // porcentaje de prueba
expose fixed O_VALIDA: Int = 9       // porcentaje de validación
expose fixed O_MAXDOC: Int = 10      // tamaño máximo de un documento
expose fixed O_DVAL: Int = 11        // % de validación de los diálogos
expose fixed O_DPRU: Int = 12        // % de prueba de los diálogos
expose fixed D_CTRL: Int = 16        // por documento: controles quitados
expose fixed D_FFD: Int = 17         // por documento: U+FFFD
expose fixed D_CHARS: Int = 18       // por documento: caracteres
expose fixed D_CR: Int = 19          // por documento: tenía CR
expose fixed D_BOM: Int = 20         // por documento: tenía BOM
expose fixed D_NFC: Int = 21         // por documento: composiciones NFC
expose fixed D_MARC: Int = 22        // por documento: marcas combinantes sin componer
expose fixed X_TIPO: Int = 24        // tipo del archivo actual (0 TEXTO, 1 DIALOGO)
expose fixed X_IDH: Int = 25         // hash de la identidad del archivo
expose fixed X_IDX: Int = 26         // índice del documento dentro del archivo
expose fixed X_ABORT: Int = 27       // != 0: error fatal
expose fixed X_JSON: Int = 28        // 1: el archivo actual es JSONL
expose fixed C_ARCH: Int = 32
expose fixed C_ILEG: Int = 33
expose fixed C_CRUDOS: Int = 34
expose fixed C_PARTES: Int = 35
expose fixed C_SEPARADORES: Int = 36
expose fixed C_CP1252: Int = 37
expose fixed C_REPAR: Int = 38
expose fixed C_BOM: Int = 39
expose fixed C_CR: Int = 40
expose fixed C_CTRL: Int = 41
expose fixed C_MOJIBAKE: Int = 42
expose fixed C_BASURA: Int = 43
expose fixed C_LETRAS: Int = 44
expose fixed C_CORTOS: Int = 45      // 45 texto, 46 diálogo
expose fixed C_EXACTOS: Int = 47
expose fixed C_CASI: Int = 48
expose fixed C_FFD: Int = 49
expose fixed C_ENTRADA: Int = 50     // bytes leídos de los archivos
expose fixed C_JLEIDAS: Int = 51     // JSONL: líneas no vacías (conversaciones leídas)
expose fixed C_JCONV: Int = 52       // JSONL: convertidas con al menos un turno
expose fixed C_JINV: Int = 53        // JSONL: líneas inválidas
expose fixed C_JVACIAS: Int = 54     // JSONL: válidas pero sin turnos
expose fixed C_JTU: Int = 55         // JSONL: turnos TÚ
expose fixed C_JENCA: Int = 56       // JSONL: turnos ENCA
expose fixed C_JSYS: Int = 57        // JSONL: mensajes system omitidos
expose fixed C_JARCH: Int = 58       // JSONL: archivos
expose fixed C_NFC: Int = 59         // composiciones NFC hechas
expose fixed C_MARC: Int = 60        // marcas combinantes sin componer
expose fixed S_OFF: Int = 64         // 3: bytes escritos por partición
expose fixed S_CRC: Int = 67         // 3: CRC32C en curso (sin invertir)
expose fixed S_DOCS: Int = 72        // 6: documentos [partición*2 + tipo]
expose fixed S_BYTES: Int = 80       // 6: bytes [partición*2 + tipo]
expose fixed M_EX: Int = 100         // bytes de la tabla de exactos
expose fixed M_BAND: Int = 101       // bytes de la tabla de bandas
expose fixed M_SIG: Int = 102        // bytes reservados para firmas
// Analizador JSONL: cursor, longitud, error, motivo (1 sintaxis, 2 rol
// desconocido, 3 forma, 4 línea demasiado larga, 5 UTF-8 inválido), longitud
// lógica del documento, marca de trabajo, claves vistas, inicio de pasada,
// contadores temporales de la conversación, ejemplos y registro de inválidas.
expose fixed J_POS: Int = 104
expose fixed J_LEN: Int = 105
expose fixed J_ERR: Int = 106
expose fixed J_MOTIVO: Int = 107
expose fixed J_N: Int = 108
expose fixed J_ALTO: Int = 109
expose fixed J_VISTAS: Int = 110
expose fixed J_INI: Int = 111
expose fixed J_T_TU: Int = 112
expose fixed J_T_EN: Int = 113
expose fixed J_T_SY: Int = 114
expose fixed J_NEJ: Int = 115        // ejemplos guardados (máx. 2)
expose fixed J_EJ: Int = 116         // 2: nº de documento de entrenamiento
expose fixed J_NLOG: Int = 118       // entradas del registro de inválidas
expose fixed J_LOG: Int = 120        // 24: (archivo << 40) | (motivo << 32) | línea
expose fixed G_TAM: Int = 192

// ---- Ranuras de la lista de trabajo K ----
expose fixed K_MINS: Int = 0         // 32 casillas de MinHash
expose fixed K_SIG: Int = 32         // 8 palabras de firma
expose fixed K_ANILLO: Int = 40      // 5 hashes de palabra
expose fixed K_CRC: Int = 80         // tabla CRC32C (256)
expose fixed K_LET: Int = 336        // 128: ASCII visible (1) y letra (1 + 2^32)
expose fixed K_TOK: Int = 464        // 128: ASCII -> byte de palabra en minúscula o 0
expose fixed K_FREQ: Int = 1024      // 65537 contadores de puntos de código
expose fixed K_BF: Int = 66561       // 256 contadores de bytes (K_FREQ + 65537)
expose fixed K_TAM: Int = 66900

expose flow mezclar(x: Int) => Int {
    change h = x
    h = (h ^ (h >> 33)) *% 0xff51afd7ed558ccd
    h = (h ^ (h >> 33)) *% 0xc4ceb9fe1a85ec53
    give h ^ (h >> 33)
}

// Rellena las tablas fijas de K: CRC32C (Castagnoli reflejado), clases ASCII
// para letras, símbolos de palabra para MinHash.
expose flow iniciarTablas(k: edit List of[Int]) {
    each b among 0..128 {
        change vis = 0
        change tok = 0
        when b > 32 && b < 127 { vis = 1 }
        when (b >= 65 && b <= 90) || (b >= 97 && b <= 122) {
            vis = 1 + 4294967296
        }
        when b >= 48 && b <= 57 { tok = b }
        when b >= 97 && b <= 122 { tok = b }
        when b >= 65 && b <= 90 { tok = b + 32 }
        k[K_LET + b] = vis
        k[K_TOK + b] = tok
    }
    each n among 0..256 {
        change c = n
        each j among 0..8 {
            when (c & 1) == 1 {
                c = 0x82F63B78 ^ (c >> 1)
            } otherwise {
                c = c >> 1
            }
        }
        k[K_CRC + n] = c
    }
}

// Actualiza el registro CRC (inicial 0xFFFFFFFF, sin inversión final).
expose flow crcLista(k: view List of[Int], crc: Int, b: view List of[Int], n: Int) => Int {
    change c = crc
    change i = 0
    during i < n {
        c = k[K_CRC + ((c ^ b[i]) & 255)] ^ (c >> 8)
        i += 1
    }
    give c
}

// CRC de una palabra de 64 bits en little-endian.
expose flow crcPalabra(k: view List of[Int], crc: Int, w: Int) => Int {
    change c = crc
    change j = 0
    during j < 8 {
        hold b = (w >> (j * 8)) & 255
        c = k[K_CRC + ((c ^ b) & 255)] ^ (c >> 8)
        j += 1
    }
    give c
}

expose flow crcFinal(c: Int) => Int {
    give (c ^ 0xFFFFFFFF) & 0xFFFFFFFF
}

// Escribe b en la posición n de un buffer elástico.
expose flow poner(buf: edit List of[Int], n: Int, b: Int) {
    when n < buf.length {
        buf[n] = b
    } otherwise {
        buf@push(b)
    }
}

expose flow nuevaLista(n: Int) => List of[Int] {
    change l: List of[Int] = List[]
    l@reserve(n)
    change i = 0
    during i < n {
        l@push(0)
        i += 1
    }
    give l
}

// ---- Emisión de texto a una lista de bytes ----
expose flow emitirT(md: edit List of[Int], t: Text) {
    each i among 0..t.byteLength {
        md@push(t@byteAt(i))
    }
}

expose flow emitirN(md: edit List of[Int], v: Int) {
    change n = v
    when n < 0 {
        md@push(45)
        n = 0 - n
    }
    when n == 0 {
        md@push(48)
        give
    }
    change div = 1
    during n / div >= 10 {
        div = div * 10
    }
    during div > 0 {
        md@push(48 + (n / div) % 10)
        div = div / 10
    }
}

// Número con ceros a la izquierda hasta `ancho` cifras.
expose flow emitirNAncho(md: edit List of[Int], v: Int, ancho: Int) {
    change div = 1
    change k = 1
    during k < ancho {
        div = div * 10
        k += 1
    }
    change n = v
    during div > 0 {
        md@push(48 + (n / div) % 10)
        div = div / 10
    }
}

// num/den como porcentaje con dos decimales ("12,34 %").
expose flow emitirPorcentaje(md: edit List of[Int], num: Int, den: Int) {
    change p = 0
    when den > 0 {
        p = num * 10000 / den
    }
    emitirN(edit md, p / 100)
    md@push(44)
    emitirNAncho(edit md, p % 100, 2)
    emitirT(edit md, " %")
}

expose flow emitirHex(md: edit List of[Int], v: Int, cifras: Int) {
    change j = cifras - 1
    during j >= 0 {
        hold d = (v >> (j * 4)) & 15
        when d < 10 {
            md@push(48 + d)
        } otherwise {
            md@push(55 + d)
        }
        j -= 1
    }
}

// Codifica un punto de código en UTF-8.
expose flow emitirCp(md: edit List of[Int], cp: Int) {
    when cp < 0x80 {
        md@push(cp)
    } otherwise when cp < 0x800 {
        md@push(0xC0 | (cp >> 6))
        md@push(0x80 | (cp & 63))
    } otherwise when cp < 0x10000 {
        md@push(0xE0 | (cp >> 12))
        md@push(0x80 | ((cp >> 6) & 63))
        md@push(0x80 | (cp & 63))
    } otherwise {
        md@push(0xF0 | (cp >> 18))
        md@push(0x80 | ((cp >> 12) & 63))
        md@push(0x80 | ((cp >> 6) & 63))
        md@push(0x80 | (cp & 63))
    }
}

// Escribe `n` bytes de la lista en un archivo nuevo (trunca); 0 si todo fue bien.
expose flow guardarLista(ruta: view Text, b: view List of[Int], n: Int) => Int {
    hold f = fileOpen(ruta, 2)
    when fileStatus(f) != 0 {
        hold st = fileStatus(f)
        fileClose(f)
        give st
    }
    change r = 0
    when n > 0 {
        when fileWrite(f, b, n) != n {
            r = 0 - 5
        }
    }
    hold c = fileClose(f)
    when r != 0 { give r }
    give c
}
