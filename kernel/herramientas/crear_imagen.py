#!/usr/bin/env python3
"""Crea una imagen de disco arrancable por UEFI para grabar en un USB.

    python crear_imagen.py <esp_dir> <salida.img> [MiB]

Disco GPT con una sola partición de sistema EFI (FAT32) que contiene el
árbol de <esp_dir> (EFI/BOOT/BOOTX64.EFI de Limine, boot/kernel.elf y
boot/limine/limine.conf). Sin dependencias: GPT, FAT32 y nombres largos
(VFAT) se escriben aquí a mano.

Con `--enca <carpeta ENCA>` copia antes al árbol los 18 archivos del corpus
de ENCA bajo enca/<ruta relativa> (los lee el hito 16), verificando tamaño y
CRC32. `--solo-enca <carpeta ENCA> <esp_dir>` solo hace esa copia.

Para grabarla en un USB (borra todo el USB): Rufus en modo "DD" o, en
Linux, `dd if=ele.img of=/dev/sdX bs=4M conv=fsync`. En el equipo:
arranque UEFI con Secure Boot desactivado.
"""
import os
import struct
import sys
import uuid
import zlib

SECTOR = 512
INICIO_PARTICION = 2048           # 1 MiB, alineado
TIPO_ESP = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")
FECHA = ((2026 - 1980) << 9) | (11 << 5) | 26   # 2026-11-26
HORA = 12 << 11


def crc32(datos):
    return zlib.crc32(datos) & 0xFFFFFFFF


# Corpus de ENCA del hito 16: (ruta relativa, bytes, CRC32), en orden de uso.
CORPUS_ENCA = [
    ("src/math/rng.l", 1110, 0x2AE43F83),
    ("src/math/math_utils.l", 2744, 0x47EA08A1),
    ("src/core/microcolumn.l", 4044, 0x3043F965),
    ("src/core/plasticity.l", 1637, 0x0BB5D870),
    ("src/memory/hippocampus.l", 2147, 0x289715D9),
    ("src/symbol/parser_utf8.l", 4409, 0x77292B7D),
    ("experiments/enca_exp001_xor.l", 18700, 0x5B71077B),
    ("experiments/enca_exp002_hipocampo.l", 22481, 0xF802A1CB),
    ("experiments/enca_exp003_continuo.l", 29034, 0x57895625),
    ("experiments/enca_exp004_cognitivo.l", 18835, 0x91D93A52),
    ("experiments/enca_exp005_escalas.l", 19920, 0x0DE085C7),
    ("experiments/enca_exp006_final.l", 13309, 0x85E144A7),
    ("experiments/enca_exp007_lenguaje.l", 15347, 0x8D0994F6),
    ("tests/test_math.l", 899, 0xEED0A3C4),
    ("tests/test_core.l", 773, 0x95F60129),
    ("tests/test_memory_symbol.l", 848, 0x40181782),
    ("src/memory/memoria_secuencial.l", 6428, 0xF6F435F4),
    ("src/core/corteza_bytes.l", 9353, 0xC7B19A9D),
]


def copiar_enca(origen, destino):
    """Copia (bytes idénticos) el corpus de ENCA a <destino>/enca/<ruta>."""
    for ruta, tam, crc in CORPUS_ENCA:
        datos = open(os.path.join(origen, *ruta.split("/")), "rb").read()
        if len(datos) != tam or crc32(datos) != crc:
            raise SystemExit("corpus ENCA distinto del esperado: %s (%d B, CRC32 %08X)"
                             % (ruta, len(datos), crc32(datos)))
        salida = os.path.join(destino, "enca", *ruta.split("/"))
        os.makedirs(os.path.dirname(salida), exist_ok=True)
        with open(salida, "wb") as f:
            f.write(datos)
    print("corpus ENCA: %d archivos copiados a %s" % (len(CORPUS_ENCA), os.path.join(destino, "enca")))


# ---------------------------------------------------------------- FAT32 ----

class Fat32:
    def __init__(self, sectores):
        self.sectores = sectores
        self.reservados = 32
        self.fats = 2
        # Tamaño de la FAT: punto fijo (cada cluster = 1 sector).
        fat = 1
        while True:
            datos = sectores - self.reservados - self.fats * fat
            necesario = ((datos + 2) * 4 + SECTOR - 1) // SECTOR
            if necesario <= fat:
                break
            fat = necesario
        self.fat_sectores = fat
        self.primer_dato = self.reservados + self.fats * fat
        self.clusters = sectores - self.primer_dato
        if self.clusters < 65525:
            raise SystemExit("imagen demasiado pequeña para FAT32")
        self.tabla = [0] * (self.clusters + 2)
        self.tabla[0] = 0x0FFFFFF8
        self.tabla[1] = 0x0FFFFFFF
        self.siguiente = 2
        self.contenido = {}   # cluster -> bytes

    def reservar_cadena(self, datos):
        """Guarda `datos` en clusters encadenados; devuelve el primero."""
        cuantos = max(1, (len(datos) + SECTOR - 1) // SECTOR)
        primero = self.siguiente
        for i in range(cuantos):
            c = primero + i
            self.tabla[c] = c + 1 if i + 1 < cuantos else 0x0FFFFFFF
            self.contenido[c] = datos[i * SECTOR:(i + 1) * SECTOR]
        self.siguiente += cuantos
        return primero

    def imagen(self, oculto, etiqueta=b"ELE KERNEL "):
        b = bytearray(self.sectores * SECTOR)
        arranque = bytearray(SECTOR)
        arranque[0:3] = b"\xEB\x58\x90"
        arranque[3:11] = b"ELE     "
        struct.pack_into("<HBHBHHBHHHII", arranque, 11, SECTOR, 1, self.reservados, self.fats,
                         0, 0, 0xF8, 0, 32, 64, oculto, self.sectores)
        struct.pack_into("<IHHIHH", arranque, 36, self.fat_sectores, 0, 0, 2, 1, 6)
        struct.pack_into("<BBBI", arranque, 64, 0x80, 0, 0x29, 0x454C4501)
        arranque[71:82] = etiqueta
        arranque[82:90] = b"FAT32   "
        arranque[510:512] = b"\x55\xAA"
        info = bytearray(SECTOR)
        libres = self.clusters + 2 - self.siguiente
        struct.pack_into("<I", info, 0, 0x41615252)
        struct.pack_into("<III", info, 484, 0x61417272, libres, self.siguiente)
        struct.pack_into("<I", info, 508, 0xAA550000)
        for base in (0, 6):
            b[base * SECTOR:(base + 1) * SECTOR] = arranque
            b[(base + 1) * SECTOR:(base + 2) * SECTOR] = info
        tabla = struct.pack("<%dI" % len(self.tabla), *self.tabla)
        for f in range(self.fats):
            inicio = (self.reservados + f * self.fat_sectores) * SECTOR
            b[inicio:inicio + len(tabla)] = tabla
        for c, datos in self.contenido.items():
            inicio = (self.primer_dato + c - 2) * SECTOR
            b[inicio:inicio + len(datos)] = datos
        return b


def nombre_corto(nombre, usados):
    base, _, ext = nombre.upper().rpartition(".")
    if not base:
        base, ext = ext, ""
    limpio = lambda s: "".join(ch for ch in s if ch.isalnum() or ch in "_-")
    base, ext = limpio(base), limpio(ext)[:3]
    if len(base) <= 8 and nombre.upper() == (base + ("." + ext if ext else "")):
        corto = base.ljust(8) + ext.ljust(3)
        if corto not in usados:
            return corto.encode("ascii"), False
    n = 1
    while True:
        sufijo = "~%d" % n
        corto = (base[:8 - len(sufijo)] + sufijo).ljust(8) + ext.ljust(3)
        if corto not in usados:
            return corto.encode("ascii"), True
        n += 1


def entradas_lfn(nombre, corto):
    suma = 0
    for byte in corto:
        suma = (((suma & 1) << 7) + (suma >> 1) + byte) & 0xFF
    unidades = nombre.encode("utf-16-le")
    unidades = [unidades[i:i + 2] for i in range(0, len(unidades), 2)] + [b"\x00\x00"]
    while len(unidades) % 13:
        unidades.append(b"\xFF\xFF")
    trozos = [unidades[i:i + 13] for i in range(0, len(unidades), 13)]
    salida = []
    for i, trozo in reversed(list(enumerate(trozos))):
        e = bytearray(32)
        e[0] = (i + 1) | (0x40 if i == len(trozos) - 1 else 0)
        e[1:11] = b"".join(trozo[0:5])
        e[11], e[12], e[13] = 0x0F, 0, suma
        e[14:26] = b"".join(trozo[5:11])
        e[28:32] = b"".join(trozo[11:13])
        salida.append(bytes(e))
    return salida


def entrada(corto, atributos, cluster, tamano):
    e = bytearray(32)
    e[0:11] = corto
    e[11] = atributos
    struct.pack_into("<HHHHHHHI", e, 14, HORA, FECHA, FECHA, cluster >> 16, HORA, FECHA, cluster & 0xFFFF, tamano)
    return bytes(e)


def escribir_directorio(fs, ruta, cluster_propio, cluster_padre):
    """Escribe el directorio `ruta` (ya con su cluster reservado)."""
    entradas = []
    if cluster_padre is not None:
        entradas.append(entrada(b".          ", 0x10, cluster_propio, 0))
        entradas.append(entrada(b"..         ", 0x10, cluster_padre, 0))
    usados = set()
    for nombre in sorted(os.listdir(ruta)):
        completo = os.path.join(ruta, nombre)
        corto, largo = nombre_corto(nombre, usados)
        usados.add(corto.decode("ascii"))
        if os.path.isdir(completo):
            cluster = fs.reservar_cadena(b"\0" * SECTOR * 4)
            escribir_directorio(fs, completo, cluster, cluster_propio if cluster_padre is not None else 0)
            atributos, tamano = 0x10, 0
        else:
            datos = open(completo, "rb").read()
            cluster = fs.reservar_cadena(datos) if datos else 0
            atributos, tamano = 0x20, len(datos)
        if largo or nombre != nombre.upper():
            entradas.extend(entradas_lfn(nombre, corto))
        entradas.append(entrada(corto, atributos, cluster, tamano))
    datos = b"".join(entradas)
    if len(datos) > SECTOR * 4:
        raise SystemExit("directorio demasiado grande: " + ruta)
    datos = datos.ljust(SECTOR * 4, b"\0")
    c = cluster_propio
    for i in range(4):
        fs.contenido[c + i] = datos[i * SECTOR:(i + 1) * SECTOR]


# ----------------------------------------------------------------- GPT -----

def gpt(total, particion_inicio, particion_fin, disco, unico):
    entradas = bytearray(128 * 128)
    entradas[0:16] = TIPO_ESP.bytes_le
    entradas[16:32] = unico.bytes_le
    struct.pack_into("<QQQ", entradas, 32, particion_inicio, particion_fin, 0)
    entradas[56:56 + 2 * len("ELE EFI")] = "ELE EFI".encode("utf-16-le")
    crc_entradas = crc32(bytes(entradas))

    def cabecera(propia, otra, lba_entradas):
        h = bytearray(92)
        h[0:8] = b"EFI PART"
        struct.pack_into("<IIIIQQQQ", h, 8, 0x00010000, 92, 0, 0, propia, otra, 34, total - 34)
        h[56:72] = disco.bytes_le
        struct.pack_into("<QIII", h, 72, lba_entradas, 128, 128, crc_entradas)
        struct.pack_into("<I", h, 16, crc32(bytes(h)))
        return bytes(h).ljust(SECTOR, b"\0")

    mbr = bytearray(SECTOR)
    struct.pack_into("<BBBBBBBBII", mbr, 446, 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(total - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xAA"
    return bytes(mbr), cabecera(1, total - 1, 2), cabecera(total - 1, 1, total - 33), bytes(entradas)


def main():
    args = sys.argv[1:]
    enca = None
    if args and args[0] == "--solo-enca":
        copiar_enca(args[1], args[2])
        return
    if "--enca" in args:
        i = args.index("--enca")
        enca = args[i + 1]
        del args[i:i + 2]
    origen, destino = args[0], args[1]
    mib = int(args[2]) if len(args) > 2 else 64
    if enca:
        copiar_enca(enca, origen)
    total = mib * 1024 * 1024 // SECTOR
    fin = total - 34
    sectores = fin - INICIO_PARTICION + 1
    fs = Fat32(sectores)
    raiz = fs.reservar_cadena(b"\0" * SECTOR * 4)
    escribir_directorio(fs, origen, raiz, None)
    particion = fs.imagen(INICIO_PARTICION)
    mbr, primaria, respaldo, entradas = gpt(total, INICIO_PARTICION, fin, uuid.uuid4(), uuid.uuid4())
    with open(destino, "wb") as f:
        f.truncate(total * SECTOR)
        f.seek(0)
        f.write(mbr + primaria + entradas)
        f.seek(INICIO_PARTICION * SECTOR)
        f.write(particion)
        f.seek((total - 33) * SECTOR)
        f.write(entradas + respaldo)
    print("imagen: %s (%d MiB, FAT32 de %d clusters)" % (destino, mib, fs.clusters))


if __name__ == "__main__":
    main()
