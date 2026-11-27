#!/usr/bin/env python3
"""Comprobación independiente de la salida de preparar.l.

    python -I verificar.py <carpeta_salida> [--sin-prueba] [--jsonl A.jsonl ...] [--texto A.txt ...]

Comprueba con las reglas del kernel (kernel/enca/espanol.l): magia ELEIDX01,
versión 1, CRC32C de la cabecera (palabras 0..8), tamaño del índice, CRC32C
de la tabla y de cada .bin, y cada documento dentro de su archivo. Además
comprueba la normalización de cada documento (UTF-8 válido, sin CR ni
controles, sin espacios finales, una línea en blanco como máximo, termina en
un solo salto) y que el .tipos coincide con el CRC y el nº de diálogos de la
cabecera. Con --sin-prueba no abre prueba_sellada (la prueba no se toca).
Imprime los CRC32C de todos los archivos (para comparar dos ejecuciones).

--jsonl A.jsonl (repetible): relee el JSONL con json de Python, aplica las
mismas reglas de conversión (formatos messages / conversations / prompt-response,
roles, turnos "TÚ:" / "ENCA:", blancos reducidos), la limpieza y la composición
NFC, y compara byte a byte con los documentos DIALOGO de la salida, buscándolos
por contenido. Los ausentes se clasifican (duplicado exacto, corto, pocas
letras, otro) y se compara el recuento con ESTADISTICAS.md.
--texto A.txt (repetible): igual para un archivo de texto: limpieza + NFC de
Python (unicodedata) y búsqueda del documento resultante en la salida.
(No repite la reparación de mojibake ni la conversión Windows-1252.)
"""
import json
import os
import re
import struct
import sys
import unicodedata

MAGIA = int.from_bytes(b"ELEIDX01", "little")

try:
    from crc32c import crc32c as _crc  # opcional, si está instalado

    def crc32c(d):
        return _crc(bytes(d))
except Exception:
    def _tabla():
        t = []
        for n in range(256):
            c = n
            for _ in range(8):
                c = (0x82F63B78 ^ (c >> 1)) if c & 1 else c >> 1
            t.append(c)
        return t

    _T = _tabla()

    def crc32c(datos):
        c = 0xFFFFFFFF
        for b in datos:
            c = _T[(c ^ b) & 0xFF] ^ (c >> 8)
        return c ^ 0xFFFFFFFF

JSONLS = []
errores = []
DOCS = []  # (partición, número, bytes, tipo) de entrena, valida y prueba


def fallo(msg):
    errores.append(msg)
    print("FALLO:", msg)


def leer(ruta):
    with open(ruta, "rb") as f:
        return f.read()


def comprobar_doc(d, nombre):
    if not d.endswith(b"\n") or d.endswith(b"\n\n") or d.endswith(b" \n"):
        fallo(nombre + ": no termina en un solo salto o tiene espacio final")
    try:
        t = d.decode("utf-8")
    except UnicodeDecodeError:
        fallo(nombre + ": UTF-8 inválido")
        return
    if "\r" in t or "\t" in t or "﻿" in t:
        fallo(nombre + ": CR, tab o BOM presente")
    for ch in t:
        o = ord(ch)
        if (o < 32 and ch != "\n") or o == 127 or 0x80 <= o <= 0x9F:
            fallo(nombre + ": carácter de control U+%04X" % o)
            break
    if "\n\n\n" in t:
        fallo(nombre + ": más de una línea en blanco seguida")
    for ln in t.split("\n"):
        if ln.endswith(" "):
            fallo(nombre + ": espacio al final de línea")
            break
    if t[:1] in (" ", "\n"):
        fallo(nombre + ": empieza en blanco")


# ---- Espejo en Python de la conversión JSONL y de la limpieza ----

def limpiar_py(t):
    """Misma limpieza que limpiar() de texto.l (sin la composición NFC)."""
    t = t.replace("\r\n", "\n").replace("\r", "\n")
    o = []
    i0 = 1 if t[:1] == "\ufeff" else 0
    for ch in t[i0:]:
        cp = ord(ch)
        if 32 < cp < 127:
            o.append(ch)
        elif cp == 10 or cp in (0x2028, 0x2029):
            while o and o[-1] == " ":
                o.pop()
            k = len(o)
            c = 0
            while k > 0 and o[k - 1] == "\n" and c < 2:
                k -= 1
                c += 1
            if o and c < 2:
                o.append("\n")
        elif cp in (9, 32, 0xA0) or 0x2000 <= cp <= 0x200A:
            if o:
                o.append(" ")
        elif (cp < 32 or cp == 127 or 0x80 <= cp <= 0x9F or cp == 0xAD
              or 0x200B <= cp <= 0x200F or 0x202A <= cp <= 0x202E or cp == 0xFEFF):
            pass
        else:
            o.append(ch)
    while o and o[-1] in "\n ":
        o.pop()
    if o:
        o.append("\n")
    return "".join(o)


def normalizar_py(t):
    return unicodedata.normalize("NFC", limpiar_py(t))


def _constante(c):
    raise ValueError("constante no válida: " + c)


def _sustituto_suelto(x):
    if isinstance(x, str):
        return any(0xD800 <= ord(c) <= 0xDFFF for c in x)
    if isinstance(x, list):
        return any(_sustituto_suelto(v) for v in x)
    if isinstance(x, dict):
        return any(_sustituto_suelto(k) or _sustituto_suelto(v) for k, v in x.items())
    return False


def _min_ascii(t):
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in t)


ROL_TU = ("user", "human", "usuario")
ROL_ENCA = ("assistant", "gpt", "bot", "model", "enca")


def _turno(texto):
    return re.sub(r"[ \t\n\r]+", " ", texto).strip(" ")


def convertir_linea(b, primera):
    """-> None si es inválida, o (documento, turnos_tu, turnos_enca, system)."""
    if primera and b[:3] == b"\xef\xbb\xbf":
        b = b[3:]
    try:
        obj = json.loads(b.decode("utf-8"), parse_constant=_constante)
    except Exception:
        return None
    if not isinstance(obj, dict) or _sustituto_suelto(obj):
        return None
    turnos = []  # (rol, texto)
    if "messages" in obj or "conversations" in obj:
        if "messages" in obj:
            lista, kr, kc = obj["messages"], "role", "content"
        else:
            lista, kr, kc = obj["conversations"], "from", "value"
        if not isinstance(lista, list):
            return None
        for m in lista:
            if not isinstance(m, dict) or kr not in m or kc not in m:
                return None
            if not isinstance(m[kr], str) or not isinstance(m[kc], str):
                return None
            r = _min_ascii(m[kr])
            if r in ROL_TU:
                turnos.append(("TÚ", m[kc]))
            elif r in ROL_ENCA:
                turnos.append(("ENCA", m[kc]))
            elif r == "system":
                turnos.append(("system", m[kc]))
            else:
                return None
    else:
        kp = next((k for k in ("prompt", "instruction", "input") if k in obj), None)
        kq = next((k for k in ("response", "output", "completion") if k in obj), None)
        if kp is None or kq is None:
            return None
        if not isinstance(obj[kp], str) or not isinstance(obj[kq], str):
            return None
        turnos = [("TÚ", obj[kp]), ("ENCA", obj[kq])]
    doc = []
    tu = en = sy = 0
    for rol, txt in turnos:
        if rol == "system":
            sy += 1
            continue
        t = _turno(txt)
        if not t:
            continue
        doc.append("%s: %s\n" % (rol, t))
        if rol == "TÚ":
            tu += 1
        else:
            en += 1
    return "".join(doc), tu, en, sy


def leer_jsonl(ruta):
    """Lee un .jsonl y devuelve los contadores y la lista de documentos."""
    datos = leer(ruta)
    lineas = datos.split(b"\n")
    if lineas and lineas[-1] == b"":
        lineas.pop()
    c = dict(leidas=0, conv=0, vacias=0, inval=0, tu=0, en=0, sy=0, inval_lineas=[])
    docs = []
    for n, b in enumerate(lineas, 1):
        if not b.strip(b" \t\r\n"):
            continue
        c["leidas"] += 1
        r = convertir_linea(b, n == 1)
        if r is None:
            c["inval"] += 1
            c["inval_lineas"].append(n)
            continue
        doc, tu, en, sy = r
        c["tu"] += tu
        c["en"] += en
        c["sy"] += sy
        if not doc:
            c["vacias"] += 1
            continue
        c["conv"] += 1
        docs.append(doc)
    return c, docs


def estadistica(carpeta, etiqueta):
    """Valor numérico de una fila '| etiqueta... | N |' de ESTADISTICAS.md."""
    ruta = os.path.join(carpeta, "ESTADISTICAS.md")
    if not os.path.exists(ruta):
        return None
    for ln in open(ruta, encoding="utf-8"):
        m = re.match(r"\| (.*?) \| (\d+) \|$", ln.strip())
        if m and m.group(1).startswith(etiqueta):
            return int(m.group(2))
    return None


def buscar(esperados, tipo_exigido):
    """Compara los documentos esperados con DOCS (multiconjunto por contenido)."""
    por_cont = {}
    for et, j, b, t in DOCS:
        por_cont.setdefault(b, []).append((et, j, t))
    hallados = 0
    ausentes = {"duplicado exacto": 0, "corto": 0, "pocas letras": 0, "otro": 0}
    vistos = set()
    for t in esperados:
        b = t.encode("utf-8")
        lista = por_cont.get(b)
        if lista:
            et, j, tipo = lista.pop(0)
            hallados += 1
            if tipo_exigido is not None and tipo != tipo_exigido:
                fallo("documento hallado en %s #%d con tipo %d (se esperaba %d)" % (et, j, tipo, tipo_exigido))
        elif b in vistos:
            ausentes["duplicado exacto"] += 1
        elif len(b) < 40:
            ausentes["corto"] += 1
        else:
            vis = [ch for ch in t if not ch.isspace()]
            let = sum(1 for ch in vis if ch.isalpha())
            if vis and let * 100 < 50 * len(vis):
                ausentes["pocas letras"] += 1
            else:
                ausentes["otro"] += 1
        vistos.add(b)
    return hallados, ausentes


def comprobar_jsonl(ruta, carpeta, sin_prueba):
    print("JSONL %s" % ruta)
    c, docs = leer_jsonl(ruta)
    esperados = [normalizar_py(d) for d in docs]
    print("  python: leídas %d, convertidas %d, sin turnos %d, inválidas %d (líneas %s), TÚ %d, ENCA %d, system %d" % (
        c["leidas"], c["conv"], c["vacias"], c["inval"], c["inval_lineas"][:24], c["tu"], c["en"], c["sy"]))
    hallados, aus = buscar(esperados, 1)
    print("  hallados byte a byte en la salida: %d de %d; ausentes: %s" % (hallados, len(esperados), aus))
    # Recuentos de ESTADISTICAS.md (solo si se verificó un único .jsonl).
    comp = [("conversaciones leídas de JSONL", c["leidas"]), ("conversaciones convertidas", c["conv"]),
            ("conversaciones válidas sin turnos", c["vacias"]), ("turnos TÚ", c["tu"]),
            ("turnos ENCA", c["en"]), ("mensajes system omitidos", c["sy"]),
            ("jsonl inválido", c["inval"])]
    if len(JSONLS) == 1:
        for et, v in comp:
            e = estadistica(carpeta, et)
            if e is None or e != v:
                fallo("ESTADISTICAS.md '%s': %s, python %d" % (et, e, v))
    otros = aus["otro"]
    permitido = sum(estadistica(carpeta, k) or 0 for k in
                    ("casi duplicados", "basura: caracteres", "basura: pocas letras", "mojibake no reparable"))
    if sin_prueba:
        print("  (con --sin-prueba, los ausentes pueden estar en la prueba sellada)")
    elif otros > permitido:
        fallo("%d documentos esperados no están y no los explican los descartes de ESTADISTICAS.md (%d)" % (otros, permitido))
    elif otros:
        print("  aviso: %d ausentes 'otro' explicables por casi duplicados/basura (%d en ESTADISTICAS.md)" % (otros, permitido))


def comprobar_texto(ruta, carpeta, sin_prueba):
    print("TEXTO %s" % ruta)
    datos = leer(ruta)
    try:
        t = datos.decode("utf-8")
    except UnicodeDecodeError:
        print("  no es UTF-8 válido: se omite")
        return
    marcas = sum(1 for ch in t if 0x300 <= ord(ch) <= 0x36F)
    docs, cur = [], []
    for ln in t.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if ln.strip(" \t") == "=====":
            if cur:
                docs.append("\n".join(cur))
            cur = []
        else:
            cur.append(ln)
    if cur:
        docs.append("\n".join(cur))
    esperados = [normalizar_py(d) for d in docs]
    esperados = [e for e in esperados if e]
    print("  marcas combinantes U+0300..U+036F en el archivo: %d; NFC cambia %d documentos" % (
        marcas, sum(1 for d in docs if unicodedata.normalize("NFC", limpiar_py(d)) != limpiar_py(d))))
    hallados, aus = buscar(esperados, None)
    print("  hallados byte a byte (limpieza + unicodedata NFC): %d de %d; ausentes: %s" % (hallados, len(esperados), aus))
    if hallados != len(esperados):
        if sin_prueba:
            print("  (con --sin-prueba, los ausentes pueden estar en la prueba sellada)")
        elif aus["otro"] > 0:
            fallo("%s: %d documentos no coinciden con la normalización de Python" % (ruta, aus["otro"]))


def comprobar(idx_ruta, bin_a, bin_b, tipos_ruta, etiqueta):
    idx = leer(idx_ruta)
    if len(idx) < 128:
        fallo(etiqueta + ": índice demasiado corto")
        return
    cab = struct.unpack("<16Q", idx[:128])
    if cab[0] != MAGIA or cab[1] != 1:
        fallo(etiqueta + ": magia o versión")
    if crc32c(idx[:72]) != cab[9]:
        fallo(etiqueta + ": CRC de la cabecera")
    nE, nP, bE, cE, bP, cP, cT = cab[2], cab[3], cab[4], cab[5], cab[6], cab[7], cab[8]
    if len(idx) != 128 + (nE + nP) * 16:
        fallo(etiqueta + ": tamaño del índice")
        return
    tabla = idx[128:]
    if crc32c(tabla) != cT:
        fallo(etiqueta + ": CRC de la tabla")
    datos = []
    for ruta, nb, cb in ((bin_a, bE, cE), (bin_b, bP, cP)):
        if ruta is None:
            datos.append(b"")
            if nb != 0:
                fallo(etiqueta + ": sección vacía con bytes")
            continue
        d = leer(ruta)
        if len(d) != nb:
            fallo("%s: %s mide %d y el índice dice %d" % (etiqueta, ruta, len(d), nb))
        if crc32c(d) != cb:
            fallo("%s: CRC de %s" % (etiqueta, ruta))
        datos.append(d)
        print("  %-40s %12d B  CRC32C %08X" % (os.path.basename(ruta), len(d), crc32c(d)))
    tipos = None
    if tipos_ruta and os.path.exists(tipos_ruta):
        tipos = leer(tipos_ruta)
        if len(tipos) != nE:
            fallo(etiqueta + ": el .tipos no tiene un byte por documento")
        if crc32c(tipos) != cab[11] or sum(tipos) != cab[10]:
            fallo(etiqueta + ": CRC o nº de diálogos de .tipos")
        print("  %-40s %12d B  CRC32C %08X  diálogos %d" % (os.path.basename(tipos_ruta), len(tipos), crc32c(tipos), sum(tipos)))
    for j in range(nE + nP):
        off, ln = struct.unpack_from("<QQ", tabla, j * 16)
        d = datos[0] if j < nE else datos[1]
        tope = bE if j < nE else bP
        if off + ln > tope:
            fallo("%s: documento %d fuera de su archivo" % (etiqueta, j))
            continue
        comprobar_doc(d[off:off + ln], "%s doc %d" % (etiqueta, j))
        if tipos_ruta is not None and tipos is not None and j < nE:
            DOCS.append((etiqueta, j, d[off:off + ln], tipos[j]))
    # Los documentos de cada .bin deben ser contiguos y cubrirlo entero.
    fin = 0
    for j in range(nE):
        off, ln = struct.unpack_from("<QQ", tabla, j * 16)
        if off != fin:
            fallo("%s: hueco antes del documento %d" % (etiqueta, j))
        fin = off + ln
    if fin != bE:
        fallo(etiqueta + ": la sección entrena no cubre todo el .bin")
    print("%s: %d + %d documentos, índice %d B, CRC32C %08X" % (etiqueta, nE, nP, len(idx), crc32c(idx)))


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    s = sys.argv[1]
    sin_prueba = "--sin-prueba" in sys.argv
    global JSONLS
    args = sys.argv[2:]
    JSONLS = [args[i + 1] for i, a in enumerate(args) if a == "--jsonl" and i + 1 < len(args)]
    textos = [args[i + 1] for i, a in enumerate(args) if a == "--texto" and i + 1 < len(args)]
    comprobar(os.path.join(s, "entrena.idx"), os.path.join(s, "entrena.bin"), None, os.path.join(s, "entrena.tipos"), "entrena")
    comprobar(os.path.join(s, "valida.idx"), os.path.join(s, "valida.bin"), None, os.path.join(s, "valida.tipos"), "valida")
    comprobar(os.path.join(s, "indice.bin"), os.path.join(s, "entrena.bin"), os.path.join(s, "valida.bin"), None, "indice.bin (entrena+valida)")
    if not sin_prueba:
        p = os.path.join(s, "prueba_sellada")
        comprobar(os.path.join(p, "prueba.idx"), os.path.join(p, "prueba.bin"), None, os.path.join(p, "prueba.tipos"), "prueba")
    nfc_mal = sum(1 for _, _, b, _ in DOCS
                  if unicodedata.normalize("NFC", b.decode("utf-8", "replace")) != b.decode("utf-8", "replace"))
    print("documentos de la salida que no están en NFC según Python: %d de %d" % (nfc_mal, len(DOCS)))
    for r in JSONLS:
        comprobar_jsonl(r, s, sin_prueba)
    for r in textos:
        comprobar_texto(r, s, sin_prueba)
    print("RESULTADO:", "CORRECTO" if not errores else "%d fallos" % len(errores))
    return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
