#!/usr/bin/env python3
"""Disco de prueba para el hito 13 (solo para QEMU).

    python crear_disco_prueba.py <salida.img> [MiB] [--enca <carpeta ENCA>]

GPT con tres particiones:
  1  "Datos Windows" (datos Microsoft), llena de 0xAB: no se debe tocar.
  2  "ELEDATOS" (datos Microsoft) en FAT32 con etiqueta ELEDATOS, como la
     preparará el usuario desde Windows: la que el kernel puede escribir.
     Lleva texto.txt (texto en español de varios MB) para el hito 14 y, con
     --enca, el corpus de ENCA bajo enca/<ruta> para el hito 16.
  3  "ELE crudo" con el GUID de tipo 7F03465A-8D62-4902-B881-2A624BFA16B6
     (también permitida; el kernel usa la primera que encuentra).
"""
import os
import struct
import sys
import tempfile
import uuid
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from crear_imagen import Fat32, escribir_directorio, copiar_enca  # noqa: E402

SECTOR = 512
ELE = uuid.UUID("7F03465A-8D62-4902-B881-2A624BFA16B6")
MSDATOS = uuid.UUID("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")


def crc32(b):
    return zlib.crc32(b) & 0xFFFFFFFF


def entrada(tipo, inicio, fin, nombre):
    e = bytearray(128)
    e[0:16] = tipo.bytes_le
    e[16:32] = uuid.uuid4().bytes_le
    struct.pack_into("<QQQ", e, 32, inicio, fin, 0)
    n = nombre.encode("utf-16-le")
    e[56:56 + len(n)] = n
    return bytes(e)




def texto_espanol(bytes_objetivo):
    """Texto en español generado (frases variadas), sin licencias de por medio."""
    sujetos = ["el sistema", "la memoria", "el núcleo", "una máquina pequeña", "el disco",
               "la red neuronal", "el compilador", "la pantalla", "el teclado", "el modelo"]
    verbos = ["aprende", "guarda", "calcula", "lee", "escribe", "recuerda", "ordena", "mide",
              "compara", "repite"]
    objetos = ["los datos del día", "una canción antigua", "el número correcto", "la última página",
               "cada palabra nueva", "el peso de la montaña", "la pregunta difícil",
               "el cálculo exacto", "las reglas del juego", "un mensaje en español"]
    lugares = ["en silencio", "con paciencia", "durante la noche", "sin perder nada",
               "antes del amanecer", "junto al río", "con mucho cuidado", "en pocos segundos"]
    lineas = []
    x = 12345
    total = 0
    while total < bytes_objetivo:
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        frase = "%s %s %s %s." % (sujetos[x % 10], verbos[(x >> 4) % 10],
                                   objetos[(x >> 8) % 10], lugares[(x >> 12) % 8])
        frase = frase[0].upper() + frase[1:]
        lineas.append(frase)
        total += len(frase.encode("utf-8")) + 1
    return ("\n".join(lineas) + "\n").encode("utf-8")


def particion_fat32(sectores, oculto, enca=None):
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "texto.txt"), "wb") as f:
            f.write(texto_espanol(3 * 1024 * 1024))
        with open(os.path.join(d, "LEEME.TXT"), "wb") as f:
            f.write(b"Particion de datos del SO en ELE.\r\n")
        if enca:
            copiar_enca(enca, d)
        fs = Fat32(sectores)
        raiz = fs.reservar_cadena(b"\0" * SECTOR * 4)
        escribir_directorio(fs, d, raiz, None)
        return fs.imagen(oculto, b"ELEDATOS   ")


def main():
    args = sys.argv[1:]
    enca = None
    if "--enca" in args:
        i = args.index("--enca")
        enca = args[i + 1]
        del args[i:i + 2]
    destino = args[0]
    mib = int(args[1]) if len(args) > 1 else 256
    total = mib * 1024 * 1024 // SECTOR
    p1 = (2048, 2048 + 32 * 2048 - 1)                     # 32 MiB
    p2 = (p1[1] + 1, p1[1] + 128 * 2048)                  # 128 MiB FAT32
    p3 = (p2[1] + 1, total - 34)
    entradas = bytearray(128 * 128)
    entradas[0:128] = entrada(MSDATOS, p1[0], p1[1], "Datos Windows")
    entradas[128:256] = entrada(MSDATOS, p2[0], p2[1], "ELEDATOS")
    entradas[256:384] = entrada(ELE, p3[0], p3[1], "ELE crudo")
    crc_e = crc32(bytes(entradas))
    disco = uuid.uuid4()

    def cabecera(propia, otra, lba_e):
        h = bytearray(92)
        h[0:8] = b"EFI PART"
        struct.pack_into("<IIIIQQQQ", h, 8, 0x00010000, 92, 0, 0, propia, otra, 34, total - 34)
        h[56:72] = disco.bytes_le
        struct.pack_into("<QIII", h, 72, lba_e, 128, 128, crc_e)
        struct.pack_into("<I", h, 16, crc32(bytes(h)))
        return bytes(h).ljust(SECTOR, b"\0")

    mbr = bytearray(SECTOR)
    struct.pack_into("<BBBBBBBBII", mbr, 446, 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, total - 1)
    mbr[510:512] = b"\x55\xAA"
    with open(destino, "wb") as f:
        f.truncate(total * SECTOR)
        f.write(bytes(mbr) + cabecera(1, total - 1, 2) + bytes(entradas))
        f.seek(p1[0] * SECTOR)
        f.write(b"\xAB" * ((p1[1] - p1[0] + 1) * SECTOR))
        f.seek(p2[0] * SECTOR)
        f.write(particion_fat32(p2[1] - p2[0] + 1, p2[0], enca))
        f.seek((total - 33) * SECTOR)
        f.write(bytes(entradas) + cabecera(total - 1, 1, total - 33))
    print("disco de prueba: %s (%d MiB; FAT32 ELEDATOS en %d-%d; ELE crudo desde %d)"
          % (destino, mib, p2[0], p2[1], p3[0]))


if __name__ == "__main__":
    main()
