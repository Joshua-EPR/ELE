#!/usr/bin/env python3
"""Genera kernel/lib/fuente.l desde una fuente de consola PSF 8x16.

Uso (en WSL/Linux, donde está console-setup):
    python3 generar_fuente.py /usr/share/consolefonts/Lat15-Fixed16.psf.gz ../lib/fuente.l

Lat15-Fixed16 deriva de las fuentes "misc-fixed" de X11 (dominio público;
console-setup: "All console fonts are public domain by nature").
Se extraen dos bloques: ASCII imprimible (U+0020..U+007E) y Latin-1
(U+00A0..U+00FF), 16 bytes por glifo, empaquetados en palabras de 64 bits
little-endian para `datos64`.
"""
import gzip
import struct
import sys


def leer_psf(ruta):
    datos = gzip.open(ruta).read() if ruta.endswith(".gz") else open(ruta, "rb").read()
    if datos[:2] == b"\x36\x04":  # PSF1
        modo, alto = datos[2], datos[3]
        cantidad = 512 if modo & 1 else 256
        ancho, bytes_glifo, inicio = 8, alto, 4
        glifos = [datos[inicio + i * alto: inicio + (i + 1) * alto] for i in range(cantidad)]
        tabla = datos[inicio + cantidad * alto:]
        unicode = {}
        if modo & 2:
            i, pos = 0, 0
            while i < cantidad and pos + 1 < len(tabla):
                cp = struct.unpack_from("<H", tabla, pos)[0]
                pos += 2
                if cp == 0xFFFF:
                    i += 1
                elif cp != 0xFFFE:
                    unicode.setdefault(cp, i)
        return ancho, alto, glifos, unicode
    magia, version, cabecera, flags, cantidad, bytes_glifo, alto, ancho = struct.unpack_from("<8I", datos)
    if magia != 0x864AB572:
        raise SystemExit("no es PSF")
    glifos = [datos[cabecera + i * bytes_glifo: cabecera + (i + 1) * bytes_glifo] for i in range(cantidad)]
    unicode = {}
    if flags & 1:
        tabla = datos[cabecera + cantidad * bytes_glifo:]
        i, pos = 0, 0
        while i < cantidad and pos < len(tabla):
            b = tabla[pos]
            if b == 0xFF:
                i += 1
                pos += 1
                continue
            if b == 0xFE:
                pos += 1
                continue
            largo = 1 if b < 0x80 else 2 if b < 0xE0 else 3 if b < 0xF0 else 4
            cp = ord(tabla[pos:pos + largo].decode("utf-8"))
            unicode.setdefault(cp, i)
            pos += largo
    return ancho, alto, glifos, unicode


def palabras(glifos):
    crudo = b"".join(glifos)
    return [struct.unpack_from("<q", crudo, i)[0] for i in range(0, len(crudo), 8)]


def hexa(valor):
    return "0x%016X" % (valor & 0xFFFFFFFFFFFFFFFF)


def bloque(nombre, comentario, valores):
    filas = []
    for i in range(0, len(valores), 4):
        filas.append("        " + ", ".join(hexa(v) for v in valores[i:i + 4]))
    cuerpo = ",\n".join(filas)
    return f"// {comentario}\nflow {nombre}() => Int {{\n    give datos64(\n{cuerpo}\n    )\n}}\n"


def main():
    origen, destino = sys.argv[1], sys.argv[2]
    ancho, alto, glifos, unicode = leer_psf(origen)
    if (ancho, alto) != (8, 16):
        raise SystemExit(f"se esperaba 8x16, no {ancho}x{alto}")

    def glifo(cp):
        return glifos[unicode.get(cp, unicode.get(ord("?")))]

    ascii_ = [glifo(cp) for cp in range(0x20, 0x7F)]
    latin1 = [glifo(cp) for cp in range(0xA0, 0x100)]
    texto = (
        "// GENERADO por herramientas/generar_fuente.py desde Lat15-Fixed16.psf\n"
        "// (fuentes misc-fixed de X11, dominio público). No editar a mano.\n"
        "//\n"
        "// Fuente 8x16: 16 bytes por glifo, una fila por byte, bit 7 = píxel\n"
        "// izquierdo.\n\n"
        "take nucleo.mem\n\n"
        + bloque("fuenteAscii", "U+0020..U+007E, 95 glifos", palabras(ascii_))
        + "\n"
        + bloque("fuenteLatin1", "U+00A0..U+00FF, 96 glifos", palabras(latin1))
        + "\n"
        "// Dirección de los 16 bytes del glifo de `cp` (otro carácter: '?').\n"
        "expose flow fuenteGlifo(cp: Int) => Int {\n"
        "    when cp >= 32 && cp <= 126 { give fuenteAscii() + (cp - 32) * 16 }\n"
        "    when cp >= 160 && cp <= 255 { give fuenteLatin1() + (cp - 160) * 16 }\n"
        "    give fuenteAscii() + (63 - 32) * 16\n"
        "}\n"
    )
    with open(destino, "w", encoding="utf-8", newline="\n") as f:
        f.write(texto)


if __name__ == "__main__":
    main()
