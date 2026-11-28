#!/usr/bin/env python3
"""Referencia de compresión sobre valida.bin (solo comprobación).

    python -I referencia_compresion.py <valida.bin> [--por-documento <valida.idx>]

Calcula con Python (Windows) lo mismo que `gzip -9` y `xz -9`: el tamaño
comprimido de todo el archivo y los bits por byte (8 * comprimido / original).
Los números que cuentan para el protocolo son los que pase el usuario con las
herramientas del sistema; esto solo sirve para comprobarlos (deben coincidir
con ellos a unos pocos bytes, por la cabecera del formato).

Con --por-documento usa el índice (formato ELEIDX01) para comprimir además
cada documento por separado y dar la media ponderada: es la cifra comparable
con un modelo que reinicia el contexto en cada documento.

Los archivos .bin se leen enteros: valida.bin pesa ~1 % del corpus. NO lo uses
con prueba.bin hasta el final de la fase.
"""
import gzip
import lzma
import struct
import sys


def bpb(comprimido, original):
    return 8.0 * comprimido / original if original else 0.0


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    datos = open(sys.argv[1], "rb").read()
    n = len(datos)
    # mtime=0: sin marca de tiempo, para que el resultado sea reproducible.
    gz = len(gzip.compress(datos, compresslevel=9, mtime=0))
    xz = len(lzma.compress(datos, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64, preset=9))
    print("archivo: %s, %d bytes" % (sys.argv[1], n))
    print("| compresor | bytes | bits/byte |")
    print("|---|---|---|")
    print("| gzip -9 | %d | %.4f |" % (gz, bpb(gz, n)))
    print("| xz -9 | %d | %.4f |" % (xz, bpb(xz, n)))
    if "--por-documento" in sys.argv:
        idx = open(sys.argv[sys.argv.index("--por-documento") + 1], "rb").read()
        nE = struct.unpack_from("<Q", idx, 16)[0]
        tg = tx = 0
        for j in range(nE):
            off, ln = struct.unpack_from("<QQ", idx, 128 + j * 16)
            d = datos[off:off + ln]
            tg += len(gzip.compress(d, compresslevel=9, mtime=0))
            tx += len(lzma.compress(d, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64, preset=9))
        print("por documento (%d documentos): gzip -9 %.4f bits/byte; xz -9 %.4f bits/byte" % (nE, bpb(tg, n), bpb(tx, n)))


if __name__ == "__main__":
    main()
