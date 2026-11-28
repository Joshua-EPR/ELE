// Preparación de corpus (Fase 4, hito 23).
//
//   preparar <lista> <carpeta_salida> [--opcion=valor ...]
//
// <lista>: UTF-8, una línea por archivo: "T|D <TAB> ruta_para_abrir <TAB> id".
// T = TEXTO, D = DIALOGO. El id (ruta relativa estable) identifica al
// documento en la partición. La carpeta de salida y su subcarpeta
// prueba_sellada deben existir (las crea preparar.ps1).
// Opciones (enteros): --min --min-dialogo --basura --letras --similitud
// --mojibake --semilla --prueba --valida --max-doc --max-docs, y
// --dialogo-reparto=E,V,P (por defecto 90,5,5; solo diálogos).
// Los archivos .jsonl (una conversación por línea) los convierte jsonl.l.
take util
take proceso
take salida

flow potencia2(n: Int) => Int {
    change p = 1024
    during p < n {
        p = p * 2
    }
    give p
}

// Valor de "clave=numero" en el argumento, -1 si no es esa clave, -2 si el
// número es inválido.
flow valorOpcion(a: view Text, clave: Text) => Int {
    hold lc = clave.byteLength
    when a.byteLength <= lc + 1 { give 0 - 1 }
    each j among 0..lc {
        when a@byteAt(j) != clave@byteAt(j) { give 0 - 1 }
    }
    when a@byteAt(lc) != 61 { give 0 - 1 }
    change v = 0
    change j = lc + 1
    during j < a.byteLength {
        hold d = a@byteAt(j) - 48
        when d < 0 || d > 9 { give 0 - 2 }
        v = v * 10 + d
        j += 1
    }
    give v
}

// ¿El argumento empieza por `clave`?
flow tienePrefijo(a: view Text, clave: Text) => Bool {
    when a.byteLength < clave.byteLength { give false }
    each j among 0..clave.byteLength {
        when a@byteAt(j) != clave@byteAt(j) { give false }
    }
    give true
}

// "--dialogo-reparto=E,V,P": porcentajes de entrenamiento, validación y
// prueba de los diálogos (suman 100; V y P como máximo 49). -1 si no es esa
// opción, 0 si se aplicó, 1 si es inválida.
flow aplicarReparto(a: view Text, g: edit List of[Int]) => Int {
    when !tienePrefijo(a, "--dialogo-reparto=") { give 0 - 1 }
    change vals = nuevaLista(3)
    change campo = 0
    change digitos = 0
    change j = 18
    during j < a.byteLength {
        hold c = a@byteAt(j)
        when c == 44 {
            when digitos == 0 || campo >= 2 { give 1 }
            campo += 1
            digitos = 0
        } otherwise when c >= 48 && c <= 57 {
            vals[campo] = vals[campo] * 10 + (c - 48)
            digitos += 1
            when vals[campo] > 100 { give 1 }
        } otherwise {
            give 1
        }
        j += 1
    }
    when campo != 2 || digitos == 0 { give 1 }
    when vals[0] + vals[1] + vals[2] != 100 { give 1 }
    when vals[1] > 49 || vals[2] > 49 { give 1 }
    g[O_DVAL] = vals[1]
    g[O_DPRU] = vals[2]
    give 0
}

// Aplica una opción; 0 si se reconoció, 1 si no.
flow aplicarOpcion(a: view Text, g: edit List of[Int]) => Int {
    hold rep = aplicarReparto(a, edit g)
    when rep != 0 - 1 { give rep }
    change v = valorOpcion(a, "--min")
    when v != 0 - 1 {
        when v < 0 { give 1 }
        g[O_MIN] = v
        give 0
    }
    v = valorOpcion(a, "--min-dialogo")
    when v != 0 - 1 {
        when v < 0 { give 1 }
        g[O_MIND] = v
        give 0
    }
    v = valorOpcion(a, "--basura")
    when v != 0 - 1 {
        when v < 0 { give 1 }
        g[O_BASURA] = v
        give 0
    }
    v = valorOpcion(a, "--letras")
    when v != 0 - 1 {
        when v < 0 { give 1 }
        g[O_LETRAS] = v
        give 0
    }
    v = valorOpcion(a, "--similitud")
    when v != 0 - 1 {
        when v < 1 || v > 100 { give 1 }
        g[O_SIM] = v
        give 0
    }
    v = valorOpcion(a, "--mojibake")
    when v != 0 - 1 {
        when v < 0 || v > 1 { give 1 }
        g[O_MOJI] = v
        give 0
    }
    v = valorOpcion(a, "--semilla")
    when v != 0 - 1 {
        when v < 0 { give 1 }
        g[O_SEMILLA] = v
        give 0
    }
    v = valorOpcion(a, "--prueba")
    when v != 0 - 1 {
        when v < 0 || v > 49 { give 1 }
        g[O_PRUEBA] = v
        give 0
    }
    v = valorOpcion(a, "--valida")
    when v != 0 - 1 {
        when v < 0 || v > 49 { give 1 }
        g[O_VALIDA] = v
        give 0
    }
    v = valorOpcion(a, "--max-doc")
    when v != 0 - 1 {
        when v < 65536 || v > 33554432 { give 1 }
        g[O_MAXDOC] = v
        give 0
    }
    v = valorOpcion(a, "--max-docs")
    when v != 0 - 1 {
        when v < 1 || v > 16000000 { give 1 }
        g[O_MAXDOCS] = v
        give 0
    }
    give 1
}

// Trabajo completo con la lista ya leída.
flow ejecutar(lista: view Text, salida: view Text, g: edit List of[Int]) => Int {
    hold maxdocs = g[O_MAXDOCS]
    change blk = nuevaLista(1048576)
    change raw = nuevaLista(g[O_MAXDOC] + 65536)
    change dec: List of[Int] = List[]
    change jd: List of[Int] = List[]
    change nor: List of[Int] = List[]
    change k = nuevaLista(K_TAM)
    iniciarTablas(edit k)
    change ex = nuevaLista(potencia2(maxdocs * 4 / 3 + 1))
    change bandas = nuevaLista(potencia2(maxdocs * 8 * 4 / 3 + 1))
    change sigs: List of[Int] = List[]
    sigs@reserve(maxdocs * 8)
    change meta: List of[Int] = List[]
    g[M_EX] = ex.length * 8
    g[M_BAND] = bandas.length * 8
    g[M_SIG] = maxdocs * 64
    each p among 0..3 {
        g[S_CRC + p] = 0xFFFFFFFF
    }
    hold pe = "{salida}/entrena.bin"
    hold pv = "{salida}/valida.bin"
    hold pp = "{salida}/prueba_sellada/prueba.bin"
    hold fe = fileOpen(pe, 2)
    hold fv = fileOpen(pv, 2)
    hold fp = fileOpen(pp, 2)
    change r = 0
    when fileStatus(fe) != 0 || fileStatus(fv) != 0 || fileStatus(fp) != 0 {
        printError("error: no se pudo crear entrena.bin, valida.bin o prueba_sellada/prueba.bin (¿existe la carpeta?)")
        r = 20
    } otherwise {
        r = recorrerLista(lista, edit blk, edit raw, edit dec, edit nor, edit k, edit g, edit ex, edit sigs, edit bandas, edit meta, fe, fv, fp, edit jd)
    }
    fileFlush(fe)
    fileFlush(fv)
    fileFlush(fp)
    fileClose(fe)
    fileClose(fv)
    fileClose(fp)
    when r == 31 {
        printError("error: se superó --max-docs; aumenta el límite y repite")
    }
    when r != 0 { give r }
    // Índices (formato ELEIDX01 v1) y archivos de tipos.
    hold ie = "{salida}/entrena.idx"
    hold te = "{salida}/entrena.tipos"
    hold iv = "{salida}/valida.idx"
    hold tv = "{salida}/valida.tipos"
    hold ip = "{salida}/prueba_sellada/prueba.idx"
    hold tp = "{salida}/prueba_sellada/prueba.tipos"
    hold ic = "{salida}/indice.bin"
    hold tc = "{salida}/_sin_tipos"
    change b = nuevaLista(70000)
    change e1 = escribirIndice(ie, te, view meta, view g, view k, edit b, 0, 0 - 1)
    change e2 = escribirIndice(iv, tv, view meta, view g, view k, edit b, 1, 0 - 1)
    change e3 = escribirIndice(ip, tp, view meta, view g, view k, edit b, 2, 0 - 1)
    // Índice combinado para el kernel actual: entrena + valida como "prueba".
    change e4 = escribirIndice(ic, tc, view meta, view g, view k, edit b, 0, 1)
    when e1 != 0 || e2 != 0 || e3 != 0 || e4 != 0 {
        printError("error: no se pudieron escribir los índices")
        give 21
    }
    hold md = "{salida}/ESTADISTICAS.md"
    hold av = "{salida}/prueba_sellada/README.md"
    hold e5 = escribirEstadisticas(md, pe, view meta, view g, edit k, edit b)
    hold e6 = escribirAvisoPrueba(av)
    when e5 != 0 || e6 != 0 {
        printError("error: no se pudo escribir ESTADISTICAS.md o el aviso de la prueba")
        give 22
    }
    // Resumen por consola.
    print("preparar: archivos {g[C_ARCH]} (ilegibles {g[C_ILEG]}), bytes leidos {g[C_ENTRADA]}, documentos crudos {g[C_CRUDOS]}")
    print("preparar: entrena {docsTotal(view g, 0)} docs {g[S_OFF]} B crc {hexDe(crcFinal(g[S_CRC]))}")
    print("preparar: valida {docsTotal(view g, 1)} docs {g[S_OFF + 1]} B crc {hexDe(crcFinal(g[S_CRC + 1]))}")
    print("preparar: prueba {docsTotal(view g, 2)} docs {g[S_OFF + 2]} B crc {hexDe(crcFinal(g[S_CRC + 2]))}")
    print("preparar: descartes cortos {g[C_CORTOS] + g[C_CORTOS + 1]} basura {g[C_BASURA]} letras {g[C_LETRAS]} mojibake {g[C_MOJIBAKE]} exactos {g[C_EXACTOS]} casi {g[C_CASI]}")
    print("preparar: conversiones cp1252 {g[C_CP1252]} mojibake-reparado {g[C_REPAR]} bom {g[C_BOM]} cr {g[C_CR]} nfc {g[C_NFC]} marcas-sin-componer {g[C_MARC]}")
    when g[C_JARCH] > 0 {
        print("preparar: jsonl archivos {g[C_JARCH]} conversaciones leidas {g[C_JLEIDAS]} convertidas {g[C_JCONV]} sin-turnos {g[C_JVACIAS]} invalidas {g[C_JINV]} turnos TU {g[C_JTU]} ENCA {g[C_JENCA]} system-omitidos {g[C_JSYS]}")
    }
    give 0
}

flow docsTotal(g: view List of[Int], p: Int) => Int {
    give g[S_DOCS + p * 2] + g[S_DOCS + p * 2 + 1]
}

flow hexDe(v: Int) => Text {
    change l: List of[Int] = List[]
    emitirHex(edit l, v, 8)
    choose textFromBytes(l, 8) {
        Ok(t): { give t },
        Err(c): { give "?" },
    }
}

flow main() => Int {
    hold n = processArgCount()
    when n < 2 {
        printError("uso: preparar <lista> <carpeta_salida> [--min=N --min-dialogo=N --basura=N --letras=N --similitud=N --mojibake=0|1 --semilla=N --prueba=N --valida=N --max-doc=N --max-docs=N --dialogo-reparto=E,V,P]")
        give 2
    }
    change g = nuevaLista(G_TAM)
    g[O_MIN] = 200
    g[O_MIND] = 40
    g[O_BASURA] = 10
    g[O_LETRAS] = 50
    g[O_SIM] = 80
    g[O_MAXDOCS] = 600000
    g[O_MOJI] = 1
    g[O_SEMILLA] = 1
    g[O_PRUEBA] = 1
    g[O_VALIDA] = 1
    g[O_MAXDOC] = 4194304
    g[O_DVAL] = 5
    g[O_DPRU] = 5
    each i among 2..n {
        choose processArg(i) {
            Ok(a): {
                when aplicarOpcion(view a, edit g) != 0 {
                    printError("opción no válida: {a}")
                    give 2
                }
            },
            Err(c): { give 2 },
        }
    }
    choose processArg(0) {
        Ok(lista): {
            choose processArg(1) {
                Ok(salida): {
                    choose readText(lista, 67108864) {
                        Ok(txt): { give ejecutar(view txt, view salida, edit g) },
                        Err(c): {
                            printError("error: no se pudo leer la lista de archivos ({c})")
                            give 3
                        },
                    }
                },
                Err(c): { give 2 },
            }
        },
        Err(c): { give 2 },
    }
}
