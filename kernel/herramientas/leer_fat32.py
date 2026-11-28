#!/usr/bin/env python3
"""Lector de solo lectura de la FAT32 ELEDATOS de un disco de prueba (hito 24).

    python -I leer_fat32.py <datos.img> ls
    python -I leer_fat32.py <datos.img> extraer <carpeta>      (M*.TXT, CURVA.LOG, SALIDA.TXT...: los archivos de la raíz < 1 MB)
    python -I leer_fat32.py <datos.img> ckpt [--datos]         (cabeceras de ENTREN_A/B.BIN; con --datos recalcula el CRC32C)
    python -I leer_fat32.py <A.img> comparar <B.img>           (curva y archivos de los puntos de dos discos)

Sirve para la prueba de apagón de enca=entrenar: extrae los resultados sin arrancar el
kernel y compara el CRC32C de los datos del último checkpoint de dos discos.
"""
import os
import struct
import sys


def crc32c_tabla():
    t = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (0x82F63B78 ^ (c >> 1)) if c & 1 else c >> 1
        t.append(c)
    return t


_T = crc32c_tabla()


def crc32c(datos, previo=0):
    c = previo ^ 0xFFFFFFFF
    t = _T
    for b in datos:
        c = t[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


class Disco:
    def __init__(self, ruta):
        self.f = open(ruta, "rb")
        self.f.seek(512)
        gpt = self.f.read(512)
        assert gpt[:8] == b"EFI PART", "no es GPT"
        lba_ent, n, tam = struct.unpack_from("<QII", gpt, 72)
        self.f.seek(lba_ent * 512)
        ent = self.f.read(n * tam)
        self.base = None
        for i in range(n):
            e = ent[i * tam:(i + 1) * tam]
            nombre = e[56:128].decode("utf-16-le").rstrip("\x00")
            if nombre == "ELEDATOS":
                self.base = struct.unpack_from("<Q", e, 32)[0]
        assert self.base is not None, "no hay partición ELEDATOS"
        self.f.seek(self.base * 512)
        b = self.f.read(512)
        self.spc = b[13]
        res = struct.unpack_from("<H", b, 14)[0]
        nfat = b[16]
        self.fat_sec = struct.unpack_from("<I", b, 36)[0]
        self.raiz = struct.unpack_from("<I", b, 44)[0]
        self.datos0 = res + nfat * self.fat_sec
        self.f.seek((self.base + res) * 512)
        fat = self.f.read(self.fat_sec * 512)
        self.fat = struct.unpack("<%dI" % (len(fat) // 4), fat)
        self.cb = self.spc * 512

    def cadena(self, c):
        while 2 <= c < 0x0FFFFFF8:
            yield c
            c = self.fat[c] & 0x0FFFFFFF

    def leer_cluster_run(self, c, n):
        self.f.seek((self.base + self.datos0 + (c - 2) * self.spc) * 512)
        return self.f.read(n * self.cb)

    def leer(self, primero, tam):
        trozos = []
        run0, n = None, 0
        for c in self.cadena(primero):
            if run0 is not None and c == run0 + n:
                n += 1
            else:
                if run0 is not None:
                    trozos.append(self.leer_cluster_run(run0, n))
                run0, n = c, 1
        if run0 is not None:
            trozos.append(self.leer_cluster_run(run0, n))
        return b"".join(trozos)[:tam]

    def directorio(self, cluster):
        datos = b"".join(self.leer_cluster_run(c, 1) for c in self.cadena(cluster))
        largo = {}
        out = []
        for i in range(0, len(datos), 32):
            e = datos[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                largo = {}
                continue
            if e[11] == 0x0F:
                orden = e[0] & 0x1F
                u = e[1:11] + e[14:26] + e[28:32]
                largo[orden] = u.decode("utf-16-le")
                continue
            if e[11] & 0x08:
                largo = {}
                continue
            nombre = e[:8].decode("ascii", "replace").rstrip()
            ext = e[8:11].decode("ascii", "replace").rstrip()
            corto = nombre + ("." + ext if ext else "")
            if largo:
                nl = "".join(largo[k] for k in sorted(largo)).split("\x00")[0].split("￿")[0]
            else:
                nl = corto
            cl = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
            tam = struct.unpack_from("<I", e, 28)[0]
            out.append((nl, corto, e[11], cl, tam))
            largo = {}
        return out

    def raiz_archivos(self):
        return {nl: (cl, tam, atr) for nl, corto, atr, cl, tam in self.directorio(self.raiz)}


def ranura(d, nombre):
    """(paso, bytes, crc, valida) de la cabecera de una ranura de checkpoint, o None."""
    r = d.raiz_archivos()
    if nombre not in r:
        return None
    cl, tam, _ = r[nombre]
    cab = d.leer(cl, 512) if tam >= 512 else b""
    if len(cab) < 48 or cab[:8] != b"ELECKPT1":
        return None
    version, paso, nb, crc, crch = struct.unpack_from("<QQQQQ", cab, 8)
    if crc32c(cab[:40]) != crch:
        return None
    return paso, nb, crc, cl, tam


def cmd_ckpt(d, datos):
    mejor = None
    for nombre in ("ENTREN_A.BIN", "ENTREN_B.BIN"):
        r = ranura(d, nombre)
        if r is None:
            print("%s: sin cabecera válida" % nombre)
            continue
        paso, nb, crc, cl, tam = r
        linea = "%s: paso %d, %d B de datos, CRC32C guardado 0x%08X" % (nombre, paso, nb, crc)
        if datos:
            raw = d.leer(cl, 512 + nb)[512:512 + nb]
            c = crc32c(raw)
            linea += ", recalculado 0x%08X %s" % (c, "OK" if c == crc else "DISTINTO")
        print(linea)
        if mejor is None or paso > mejor[0]:
            mejor = (paso, crc, nombre)
    if mejor:
        print("último checkpoint válido: %s paso %d CRC32C 0x%08X" % (mejor[2], mejor[0], mejor[1]))
    return mejor


def cmd_extraer(d, carpeta):
    os.makedirs(carpeta, exist_ok=True)
    for nombre, (cl, tam, atr) in sorted(d.raiz_archivos().items()):
        if atr & 0x10 or tam == 0 or tam > (1 << 20):
            continue
        if nombre.upper().startswith(("M0", "CURVA", "SALIDA")):
            with open(os.path.join(carpeta, nombre), "wb") as f:
                f.write(d.leer(cl, tam))
            print("extraído %s (%d B)" % (nombre, tam))


def cmd_comparar(a, b):
    ra, rb = a.raiz_archivos(), b.raiz_archivos()
    nombres = sorted(n for n in set(ra) | set(rb) if n.upper().startswith("M0"))
    bien = True
    print("archivos de los puntos: A %d, B %d" % (sum(1 for n in ra if n.upper().startswith("M0")),
                                                   sum(1 for n in rb if n.upper().startswith("M0"))))
    for n in nombres:
        if n not in ra or n not in rb:
            print("  %s: solo en uno de los discos" % n)
            bien = False
            continue
        da, db = a.leer(*ra[n][:2]), b.leer(*rb[n][:2])
        ok = da == db
        bien &= ok
        print("  %s: %d B, %s" % (n, len(da), "IDÉNTICO" if ok else "DISTINTO"))
    la = a.leer(*ra["CURVA.LOG"][:2]).decode().splitlines() if "CURVA.LOG" in ra else []
    lb = b.leer(*rb["CURVA.LOG"][:2]).decode().splitlines() if "CURVA.LOG" in rb else []
    print("CURVA.LOG: %d líneas en A, %d en B (se comparan las 7 primeras columnas; las dos últimas son velocidad y hora)"
          % (len(la), len(lb)))
    if len(la) != len(lb):
        bien = False
    for x, y in zip(la, lb):
        cx, cy = x.split()[:8], y.split()[:8]
        if x.startswith("#"):
            continue
        ok = cx == cy
        bien &= ok
        print("  A: %s\n  B: %s   -> %s" % (" ".join(cx), " ".join(cy), "IDÉNTICO" if ok else "DISTINTO"))
    ma, mb = cmd_ckpt(a, False), cmd_ckpt(b, False)
    if ma and mb:
        ok = ma[1] == mb[1]
        bien &= ok
        print("CRC32C de los datos del último checkpoint: A 0x%08X, B 0x%08X -> %s"
              % (ma[1], mb[1], "IDÉNTICO" if ok else "DISTINTO"))
    else:
        bien = False
    print("RESULTADO:", "TODO IDÉNTICO" if bien else "HAY DIFERENCIAS")
    return bien


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    d = Disco(sys.argv[1])
    orden = sys.argv[2]
    if orden == "ls":
        for n, (cl, tam, atr) in sorted(d.raiz_archivos().items()):
            print("%-20s %12d  %s" % (n, tam, "dir" if atr & 0x10 else ""))
    elif orden == "extraer":
        cmd_extraer(d, sys.argv[3])
    elif orden == "ckpt":
        cmd_ckpt(d, "--datos" in sys.argv)
    elif orden == "comparar":
        sys.exit(0 if cmd_comparar(d, Disco(sys.argv[3])) else 1)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
