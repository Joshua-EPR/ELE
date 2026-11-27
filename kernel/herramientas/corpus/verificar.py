#!/usr/bin/env python3
"""Comprobación independiente de la salida de preparar.l.

    python -I verificar.py <carpeta_salida> [--sin-prueba]

Comprueba con las reglas del kernel (kernel/enca/espanol.l): magia ELEIDX01,
versión 1, CRC32C de la cabecera (palabras 0..8), tamaño del índice, CRC32C
de la tabla y de cada .bin, y cada documento dentro de su archivo. Además
comprueba la normalización de cada documento (UTF-8 válido, sin CR ni
controles, sin espacios finales, una línea en blanco como máximo, termina en
un solo salto) y que el .tipos coincide con el CRC y el nº de diálogos de la
cabecera. Con --sin-prueba no abre prueba_sellada (la prueba no se toca).
Imprime los CRC32C de todos los archivos (para comparar dos ejecuciones).
"""
import os
import struct
import sys

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

errores = []


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
    comprobar(os.path.join(s, "entrena.idx"), os.path.join(s, "entrena.bin"), None, os.path.join(s, "entrena.tipos"), "entrena")
    comprobar(os.path.join(s, "valida.idx"), os.path.join(s, "valida.bin"), None, os.path.join(s, "valida.tipos"), "valida")
    comprobar(os.path.join(s, "indice.bin"), os.path.join(s, "entrena.bin"), os.path.join(s, "valida.bin"), None, "indice.bin (entrena+valida)")
    if not sin_prueba:
        p = os.path.join(s, "prueba_sellada")
        comprobar(os.path.join(p, "prueba.idx"), os.path.join(p, "prueba.bin"), None, os.path.join(p, "prueba.tipos"), "prueba")
    print("RESULTADO:", "CORRECTO" if not errores else "%d fallos" % len(errores))
    return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
