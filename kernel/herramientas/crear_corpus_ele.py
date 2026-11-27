#!/usr/bin/env python3
"""Segundo corpus de ENCA: el código fuente del compilador de ELE.

    python crear_corpus_ele.py <compiler-l/src> <carpeta_salida>

Escribe <carpeta_salida>/ele/{entrena.bin, prueba.bin, indice.bin}.

Partición fija y reproducible: todos los .l bajo <compiler-l/src>, ordenados
por ruta relativa (con "/", orden de bytes). El archivo número i (desde 0) va
a prueba si i % 10 == 9 (1 de cada 10); el resto entrena. Los de prueba nunca
se entrenan. Los archivos de cada grupo se concatenan tal cual, en ese orden.

indice.bin (palabras de 64 bits little-endian):
  cabecera de 16 palabras (128 bytes):
    0 magia "ELEIDX01"   1 versión (1)
    2 documentos de entrenamiento   3 documentos de prueba
    4 bytes de entrena.bin   5 CRC32C de entrena.bin
    6 bytes de prueba.bin    7 CRC32C de prueba.bin
    8 CRC32C de la tabla de documentos   9 CRC32C de las palabras 0..8 (72 bytes)
    10..15 ceros
  tabla: por documento (primero los de entrenamiento y luego los de prueba),
  2 palabras: desplazamiento en su .bin y longitud.
CRC32C = Castagnoli reflejado, init y final 0xFFFFFFFF (como lib/crc32.l).
"""
import os
import struct
import sys

MAGIA = int.from_bytes(b"ELEIDX01", "little")


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


def archivos_fuente(raiz):
    rutas = []
    for dirpath, _, nombres in os.walk(raiz):
        for n in nombres:
            if n.endswith(".l"):
                rel = os.path.relpath(os.path.join(dirpath, n), raiz).replace(os.sep, "/")
                rutas.append(rel)
    rutas.sort(key=lambda r: r.encode("utf-8"))
    return rutas


def preparar(raiz, destino):
    """Crea <destino>/ele/*.bin; devuelve (docs_entrena, bytes_entrena, docs_prueba, bytes_prueba)."""
    rutas = archivos_fuente(raiz)
    if not rutas:
        raise SystemExit("no hay .l bajo " + raiz)
    grupos = {"entrena": [], "prueba": []}
    for i, rel in enumerate(rutas):
        datos = open(os.path.join(raiz, *rel.split("/")), "rb").read()
        grupos["prueba" if i % 10 == 9 else "entrena"].append(datos)
    salida = os.path.join(destino, "ele")
    os.makedirs(salida, exist_ok=True)
    binarios = {}
    tabla = bytearray()
    for nombre in ("entrena", "prueba"):
        blob = b"".join(grupos[nombre])
        binarios[nombre] = blob
        with open(os.path.join(salida, nombre + ".bin"), "wb") as f:
            f.write(blob)
        desp = 0
        for d in grupos[nombre]:
            tabla += struct.pack("<QQ", desp, len(d))
            desp += len(d)
    cab = [MAGIA, 1, len(grupos["entrena"]), len(grupos["prueba"]),
           len(binarios["entrena"]), crc32c(binarios["entrena"]),
           len(binarios["prueba"]), crc32c(binarios["prueba"]),
           crc32c(bytes(tabla))]
    cab.append(crc32c(struct.pack("<9Q", *cab)))
    cab += [0] * (16 - len(cab))
    with open(os.path.join(salida, "indice.bin"), "wb") as f:
        f.write(struct.pack("<16Q", *cab) + bytes(tabla))
    print("corpus ELE: %d archivos .l de %s; entrena %d docs, %d B (CRC32C %08X); prueba %d docs, %d B (CRC32C %08X) -> %s"
          % (len(rutas), raiz, cab[2], cab[4], cab[5], cab[3], cab[6], cab[7], salida))
    return cab[2], cab[4], cab[3], cab[6]


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    preparar(sys.argv[1], sys.argv[2])
