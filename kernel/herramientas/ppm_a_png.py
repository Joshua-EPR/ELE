#!/usr/bin/env python3
"""Convierte la captura PPM (P6) de QEMU `screendump` a PNG, sin dependencias."""
import struct
import sys
import zlib


def leer_ppm(ruta):
    datos = open(ruta, "rb").read()
    campos, pos = [], 0
    while len(campos) < 4:
        while datos[pos:pos + 1].isspace():
            pos += 1
        if datos[pos:pos + 1] == b"#":
            pos = datos.index(b"\n", pos) + 1
            continue
        fin = pos
        while not datos[fin:fin + 1].isspace():
            fin += 1
        campos.append(datos[pos:fin])
        pos = fin
    if campos[0] != b"P6" or int(campos[3]) != 255:
        raise SystemExit("solo PPM P6 de 8 bits")
    return int(campos[1]), int(campos[2]), datos[pos + 1:]


def trozo(tipo, contenido):
    return struct.pack(">I", len(contenido)) + tipo + contenido + struct.pack(">I", zlib.crc32(tipo + contenido) & 0xFFFFFFFF)


def main():
    ancho, alto, pixeles = leer_ppm(sys.argv[1])
    filas = b"".join(b"\x00" + pixeles[y * ancho * 3:(y + 1) * ancho * 3] for y in range(alto))
    png = b"\x89PNG\r\n\x1a\n" + trozo(b"IHDR", struct.pack(">IIBBBBB", ancho, alto, 8, 2, 0, 0, 0))
    png += trozo(b"IDAT", zlib.compress(filas, 6)) + trozo(b"IEND", b"")
    open(sys.argv[2], "wb").write(png)


if __name__ == "__main__":
    main()
