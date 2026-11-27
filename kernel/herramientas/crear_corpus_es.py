#!/usr/bin/env python3
"""Corpus en español para ENCA: teatro y narrativa de Wikisource + Wikipedia.

    python -I crear_corpus_es.py <descargas> <salida> [fase]

<descargas> contiene eswikisource.xml.bz2 y eswiki-trozo.xml.bz2 (volcados de
dumps.wikimedia.org del 1/2-nov-2026); <salida> es corpus_es/ (no se versiona).
fase: ws | wp | armar | todo (por defecto). Cada fase guarda su resultado en
<salida>/_cache/ para no repetir el trabajo largo; "todo" las ejecuta en orden.

Salida: <salida>/completo/ y <salida>/desarrollo/, cada una con entrena.bin,
prueba.bin e indice.bin (formato idéntico al de crear_corpus_ele.py, que se
importa para el índice y el CRC32C), más <salida>/ESTADISTICAS.md.

Wikisource (dominio público). Las obras se guardan de dos modos:
  - texto directo en el espacio principal (ns 0): poemas, cuentos cortos,
    muchas obras de teatro maquetadas a mano (tablas, {{Pt|PERSONAJE:|...}});
  - texto transcluido: la página ns 0 solo lleva <pages index="X.djvu"
    from=a to=b [fromsection= tosection=]/> y el texto corregido está en el
    espacio "Página:X.djvu/n" (ns 102), con <noinclude> (cabecera/pie, que
    NO se transcluye) y marcas <section begin/end>. Se expande esa
    transclusión y luego se limpia el wikitexto.
Una "obra" es el título de ns 0 hasta la primera "/"; un documento es cada
subpágina (acto, jornada, capítulo) o la obra entera si no tiene subpáginas.
La partición entrena/prueba es POR OBRA (y por artículo), nunca por
documento suelto, para que los actos de una misma comedia no crucen.

Wikipedia (CC BY-SA 4.0): artículos ns 0 del trozo, solo prosa.
Atribución: Wikipedia en español (CC BY-SA 4.0) y Wikisource en español.

Determinista: sin aleatoriedad; el orden y la partición salen de CRC32C del
título. Dos ejecuciones dan los mismos archivos.
"""
import bz2
import collections
import gzip
import html
import io
import lzma
import os
import pickle
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crear_corpus_ele as ele  # noqa: E402  (índice y CRC32C compartidos)

# ---------------------------------------------------------------------------
# Presupuestos (bytes). Justificación en ESTADISTICAS.md.
# ---------------------------------------------------------------------------
PRESUPUESTO_ENTRENA = {  # completo
    "teatro": 8_500_000, "narrativa": 5_000_000, "poesia": 1_500_000,
    "wikipedia": 15_000_000,
}
PRESUPUESTO_PRUEBA = {
    "teatro": 300_000, "narrativa": 200_000, "poesia": 50_000,
    "wikipedia": 450_000,
}
PRESUPUESTO_DESARROLLO = {  # entrenamiento del juego de desarrollo
    "teatro": 800_000, "narrativa": 450_000, "poesia": 100_000,
    "wikipedia": 1_200_000,
}
MAX_POR_OBRA = 400_000       # una obra aporta como mucho esto (variedad)
MAX_OBRA_PRUEBA = 120_000    # obras candidatas a prueba: tamaño máximo
MIN_DOC = 1024               # descarta documentos de menos de 1 KB de texto


def crc(s):
    return ele.crc32c(s.encode("utf-8"))


# ---------------------------------------------------------------------------
# Lectura de volcados
# ---------------------------------------------------------------------------
_PAGINA = re.compile(r"<page>(.*?)</page>", re.S)
_TIT = re.compile(r"<title>(.*?)</title>", re.S)
_NS = re.compile(r"<ns>(-?\d+)</ns>")
_TEXTO = re.compile(r"<text\b[^>]*?(?:/>|>(.*?)</text>)", re.S)


def _xml(s):
    return (s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
            .replace("&apos;", "'").replace("&amp;", "&"))


def paginas(ruta):
    """Rinde (título, ns, es_redirección, texto) de un volcado .xml.bz2."""
    f = io.TextIOWrapper(bz2.open(ruta, "rb"), encoding="utf-8", errors="replace",
                         newline="")
    buf = ""
    while True:
        trozo = f.read(1 << 24)
        if not trozo:
            break
        buf += trozo
        ultimo = 0
        for m in _PAGINA.finditer(buf):
            ultimo = m.end()
            p = m.group(1)
            t = _TIT.search(p)
            n = _NS.search(p)
            x = _TEXTO.search(p)
            if not (t and n):
                continue
            yield (_xml(t.group(1)), int(n.group(1)), "<redirect" in p[:p.find("<revision>")
                                                          if "<revision>" in p else len(p)],
                   _xml(x.group(1)) if x and x.group(1) else "")
        buf = buf[ultimo:]
    f.close()


# ---------------------------------------------------------------------------
# Transclusión <pages .../> de Wikisource
# ---------------------------------------------------------------------------
_PAG = re.compile(r"<pages\s+([^>]*?)/?>", re.S)
_ATTR = re.compile(r"(\w+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'/>][^\s>]*?)(?=\s|/?>|$))", re.S)


def _attrs(s):
    d = {}
    for m in _ATTR.finditer(s):
        d[m.group(1).lower()] = next(g for g in m.groups()[1:] if g is not None)
    return d


def _lista(s):
    r = []
    for p in s.split(","):
        p = p.strip()
        if "-" in p:
            a, b = p.split("-", 1)
            if a.isdigit() and b.isdigit():
                r += range(int(a), int(b) + 1)
        elif p.isdigit():
            r.append(int(p))
    return r


def _rango(a):
    if "include" in a:
        ps = _lista(a["include"])
    else:
        f, t = a.get("from"), a.get("to")
        if f and f.isdigit() and t and t.isdigit() and int(t) >= int(f):
            ps = list(range(int(f), int(t) + 1))
        elif f and f.isdigit() and not t:
            ps = [int(f)]
        else:
            ps = []
    if "exclude" in a:
        ex = set(_lista(a["exclude"]))
        ps = [p for p in ps if p not in ex]
    return ps


def _transcluido(raw, fromsec=None, tosec=None, only=None):
    x = re.sub(r"<noinclude>.*?</noinclude>", "", raw, flags=re.S)
    x = re.sub(r"<noinclude>.*\Z", "", x, flags=re.S)
    if only:
        m = re.search(r'<section\s+begin="?%s"?\s*/>(.*?)<section\s+end="?%s"?\s*/>'
                      % (re.escape(only), re.escape(only)), x, re.S)
        x = m.group(1) if m else ""
    else:
        if fromsec:
            m = re.search(r'<section\s+begin="?%s"?\s*/>' % re.escape(fromsec), x)
            if m:
                x = x[m.end():]
        if tosec:
            m = re.search(r'<section\s+end="?%s"?\s*/>' % re.escape(tosec), x)
            if m:
                x = x[:m.start()]
    x = re.sub(r"<section\s+(?:begin|end)=[^>]*/>", "", x)
    return re.sub(r"</?includeonly>", "", x)


def expandir(x, ns102, prefijo):
    def sub(m):
        a = _attrs(m.group(1))
        idx = a.get("index")
        if not idx:
            return ""
        ps = _rango(a)
        out = []
        for k, p in enumerate(ps):
            raw = ns102.get("%s%s/%d" % (prefijo, idx, p))
            if raw is None:
                continue
            out.append(_transcluido(raw, a.get("fromsection") if k == 0 else None,
                                    a.get("tosection") if k == len(ps) - 1 else None,
                                    a.get("onlysection")))
        return "\n".join(out) + "\n"
    return _PAG.sub(sub, x)


# ---------------------------------------------------------------------------
# Limpieza de wikitexto
# ---------------------------------------------------------------------------
M1, M2 = "\x01", "\x02"  # marcas de personaje: M1 NOMBRE M2 texto

_COMENT = re.compile(r"<!--.*?-->", re.S)
_QUITAR = re.compile(
    r"<ref\b[^>]*?/>|<ref\b[^>]*>.*?</ref>|<gallery\b.*?</gallery>|<math\b.*?</math>|"
    r"<timeline\b.*?</timeline>|<imagemap\b.*?</imagemap>|<source\b.*?</source>|"
    r"<syntaxhighlight\b.*?</syntaxhighlight>|<score\b.*?</score>|<pre\b.*?</pre>|"
    r"<noinclude>.*?</noinclude>|<references\b[^>]*?/>|<references\b[^>]*>.*?</references>|"
    r"<ref\b[^>]*>.*\Z", re.S | re.I)
_ARCH = re.compile(r"\[\[\s*(?:archivo|file|imagen|image|categor[ií]a|category|media)\s*:[^\[\]]*\]\]", re.I)
_INTERLENGUA = re.compile(r"\[\[\s*[a-z]{2,3}(?:-[a-z]+)?\s*:[^\[\]]*\]\]")
_ENLACE = re.compile(r"\[\[([^\[\]|]*)\|([^\[\]]*)\]\]")
_ENLACE2 = re.compile(r"\[\[([^\[\]|]*)\]\]")
_EXT = re.compile(r"\[(?:https?:|ftp:|//)[^\s\]]*(?:\s+([^\]]*))?\]")
_TPL = re.compile(r"\{\{([^{}]*)\}\}")
_ETIQ = re.compile(r"</?[A-Za-z][^<>]*>")
_NEGCURS = re.compile(r"'{2,5}")

_CENTRA_ARG = {"may", "menor", "x-menor", "grande", "x-grande", "xx-grande", "xxx-grande",
               "asc", "sc", "versalita", "mo", "gota", "grandeinicial", "gi", "d", "ditto",
               "uc", "ma", "centrar", "bold", "cursiva", "negrita", "nowrap", "small",
               "versalitas", "mayúsculas", "mayusculas", "min", "pditto", "tdmay",
               "lang", "idioma", "subrayado", "tachado"}
_BLOQUE_ARG = {"c", "bc", "centro", "derecha", "t2", "t3", "t4", "t5", "título", "titulo"}
_LETRAS = {"s", "z", "que", "un", "es", "e", "a", "o", "u", "i", "n", "m", "q", "d", "p"}
_PERS_ARG = {"pt", "pt2", "pt/verso", "pt/versof", "npt", "pt/dir_"}
_VACIAS = {"pt/dir", "pt2/dir"}


def _positional(args):
    return [a for a in args if not re.match(r"^\s*[\wáéíóúñ ]{1,20}=", a)]


def _plantilla(m):
    cuerpo = m.group(1)
    partes = cuerpo.split("|")
    nombre = partes[0].strip().lower()
    args = partes[1:]
    pos = _positional(args)
    if nombre in _PERS_ARG:
        if len(pos) >= 2:
            return "\n" + M1 + pos[0] + M2 + "|".join(pos[1:]) + "\n"
        return "\n" + (pos[0] if pos else "") + "\n"
    if nombre == "ps":
        if len(pos) >= 2:
            return "\n" + M1 + pos[0] + M2 + pos[-1] + "\n"
        return ""
    if nombre in _VACIAS:
        return "\n" + (pos[0] if pos else "") + "\n"
    if nombre in ("c", "centrado", "centro"):
        clase = " ".join(a for a in args if "clase" in a.lower())
        if pos and re.search(r"personaje\s*$", clase.strip(), re.I):
            return "\n" + M1 + pos[0] + M2 + "\n"
        return "\n" + (pos[0] if pos else "") + "\n"
    if nombre in _BLOQUE_ARG:
        return "\n" + (pos[0] if pos else "") + "\n"
    if nombre in _CENTRA_ARG:
        if nombre in ("lang", "idioma"):
            return pos[1] if len(pos) > 1 else ""
        return pos[0] if pos else ""
    if nombre in ("--",):
        return "—"
    if nombre in ("...", "…"):
        return "..."
    if nombre in ("brecha", "tab", "sangría", "sangria"):
        return " "
    if not args:
        n = nombre.replace("^", "").replace("~", "")
        if n in _LETRAS or (re.fullmatch(r"[a-zñáéíóú][\^~]", nombre) is not None):
            return n
    return ""


def _tablas(x):
    """Tablas {| ... |} -> líneas: una por fila, con las celdas unidas.
    Si la primera celda es un personaje ("NOMBRE:"), se marca como turno."""
    patron = re.compile(r"\{\|(?:(?!\{\|).)*?\n\|\}", re.S)

    def conv(m):
        t = m.group(0)
        filas = re.split(r"\n\|-[^\n]*", t)
        out = []
        for fila in filas:
            celdas = []
            for ln in fila.split("\n"):
                s = ln.strip()
                if not s or s.startswith(("{|", "|}", "|+")):
                    continue
                if s[0] in "|!":
                    s = s[1:]
                    partes = re.split(r"\|\||!!", s)
                    for p in partes:
                        if "|" in p and not p.lstrip().startswith("["):
                            p = p.split("|", 1)[1] if re.match(r"^[^|]*=[^|]*\|", p) else p
                        celdas.append(p.strip())
                elif celdas:
                    celdas[-1] += "\n" + s
                else:
                    celdas.append(s)
            if not celdas:
                continue
            c0 = celdas[0].strip()
            c0n = re.sub(r"^'+|'+$", "", c0).strip()
            if len(celdas) >= 2 and c0n and len(c0n) <= 40 and re.fullmatch(
                    r"[A-ZÁÉÍÓÚÑÜ][A-ZÁÉÍÓÚÑÜa-záéíóúñü .,'-]*[:.]", c0n) and (
                    c0n.upper() == c0n or c0n.endswith(":")):
                out.append(M1 + c0n + M2 + " ".join(c for c in celdas[1:] if c))
            else:
                out.append(" ".join(c for c in celdas if c))
        return "\n" + "\n".join(out) + "\n"
    for _ in range(8):
        y = patron.sub(conv, x)
        if y == x:
            break
        x = y
    return x


def limpiar_wikitexto(x, wikipedia=False):
    """Wikitexto -> texto plano con marcas M1 NOMBRE M2 en los turnos de teatro."""
    x = x.replace("\r", "")
    x = _COMENT.sub("", x)
    x = _QUITAR.sub("", x)
    # enlaces (antes que las plantillas, para que no estorben los '|')
    for _ in range(4):
        y = _ARCH.sub("", x)
        y = _INTERLENGUA.sub("", y)
        y = _ENLACE.sub(lambda m: m.group(2), y)
        y = _ENLACE2.sub(lambda m: m.group(1), y)
        if y == x:
            break
        x = y
    x = _EXT.sub(lambda m: m.group(1) or "", x)
    if wikipedia:
        for _ in range(12):  # tablas, infoboxes y demás: fuera
            y = re.sub(r"\{\|(?:(?!\{\|).)*?\|\}", "", x, flags=re.S)
            if y == x:
                break
            x = y
    else:
        x = _tablas(x)
    for _ in range(20):
        y = _TPL.sub(_plantilla_wp if wikipedia else _plantilla, x)
        if y == x:
            break
        x = y
    x = x.replace("{{", "").replace("}}", "").replace("{|", "").replace("|}", "")
    x = re.sub(r"<br\s*/?>", "\n", x, flags=re.I)
    x = _ETIQ.sub("", x)
    x = _NEGCURS.sub("", x)
    x = re.sub(r"__[A-Z]+__", "", x)
    x = html.unescape(x)
    return x


def _plantilla_wp(m):
    partes = m.group(1).split("|")
    nombre = partes[0].strip().lower()
    pos = _positional(partes[1:])
    if nombre in ("nowrap", "nobr", "versalita", "small", "esd") and pos:
        return pos[0]
    if nombre in ("lang", "idioma") and len(pos) > 1:
        return pos[1]
    if nombre.startswith(("formatnum", "fechadesde")) or nombre == "esd":
        return pos[0] if pos else " "
    return ""


# ---------------------------------------------------------------------------
# Normalización de líneas y turnos de teatro
# ---------------------------------------------------------------------------
_NO_NOMBRE = re.compile(
    r"^(?:ACTO|ESCENA|SCENA|JORNADA|CUADRO|CAPITULO|CAPÍTULO|LIBRO|PARTE|TOMO|FIN|EPILOGO|"
    r"EPÍLOGO|PROLOGO|PRÓLOGO|APENDICE|APÉNDICE|NOTA|NOTAS|PERSONAJES|PERSONAS|INTERLOCUTORES|"
    r"ESCENARIO|DECORACIÓN|DECORACION|SEGUNDA|PRIMERA|TERCERA|CUARTA|QUINTA|"
    r"CANTO|TÍTULO|TITULO|PÁGINA|PAGINA|ÍNDICE|INDICE|PRÓLOGO|FRAGMENTO)\b")
_GEN = re.compile(
    r"^([A-ZÁÉÍÓÚÑÜ][A-ZÁÉÍÓÚÑÜ0-9 ,.'’ª-]{0,34}?)\s*(?:\.\s*[-—–]+\s*|[.:]\s+|[.:]\s*$|\s*[-—–]{1,2}\s+)(.*)$")
_NEG_INI = re.compile(r"^\s*'''\s*([^'\n]{1,32}?)\s*'''\s*[.:]?\s+(.*)$")


def _nombre(n):
    n = re.sub(r"\s+", " ", n.replace(" ", " ")).strip()
    n = re.sub(r"[\s.:,\-—–'’\[\]()]+$", "", n)
    n = re.sub(r"^[\s\[\](]+", "", n)
    return n.upper()


def _marcar_negrita(x):
    """Turnos con el personaje en negrita al inicio de línea (::'''ROS'''. texto)."""
    out = []
    for ln in x.split("\n"):
        m = _NEG_INI.match(ln.lstrip(":;* "))
        if m:
            nom = m.group(1)
            if (nom.upper() == nom or len(nom) <= 14) and not _NO_NOMBRE.match(nom.upper()):
                out.append(M1 + nom + M2 + m.group(2))
                continue
        out.append(ln)
    return "\n".join(out)


def _normalizar_lineas(x, teatro):
    """Limpia cada línea; en teatro reconoce turnos genéricos 'NOMBRE. texto'."""
    res = []
    for ln in x.split("\n"):
        ln = ln.replace(" ", " ").replace("​", "").replace("﻿", "")
        ln = re.sub(r"[ \t]+", " ", ln).strip()
        if ln[:1] in ("|", "!"):  # restos de tablas sin cerrar
            if re.match(r"^\|[-}+]", ln):
                ln = ""
            else:
                ln = re.sub(r"^[|!]\s*(?:[A-Za-z]+\s*=\s*[^|]*\|(?!\|))?\s*", "", ln)
                ln = ln.replace("||", " ").strip()
        if not ln:
            res.append("")
            continue
        marca = None
        if ln[0] == M1:
            nom, _, resto = ln[1:].partition(M2)
            marca, ln = _nombre(nom), resto.strip()
        else:
            ln = re.sub(r"^[:;*#]+\s*", "", ln)
            m = re.match(r"^(={2,6})\s*(.*?)\s*\1\s*$", ln)
            if m:
                ln = m.group(2)
            elif teatro:
                g = _GEN.match(ln)
                if g and not _NO_NOMBRE.match(g.group(1).strip()):
                    nom = _nombre(g.group(1))
                    if 1 < len(nom) <= 30 and sum(c.isalpha() for c in nom) >= 2:
                        marca, ln = nom, g.group(2).strip()
        ln = re.sub(r"^[-—–]{3,}$", "", ln)
        if marca is not None and 1 < len(marca) <= 30:
            res.append(M1 + marca + M2 + ln)
        elif M1 in ln or M2 in ln:
            res.append(ln.replace(M1, "").replace(M2, ""))
        else:
            res.append(ln)
    return res


def _unir_prosa(lineas):
    """Junta las líneas de un mismo párrafo cortadas por saltos de página.
    Solo en bloques que parecen prosa (líneas largas); el verso no se toca."""
    out = []
    bloque = []

    def vaciar():
        if not bloque:
            return
        if len(bloque) > 1 and all(len(b) >= 55 for b in bloque[:-1]) and not any(
                b.startswith(M1) for b in bloque[1:]):
            s = bloque[0]
            for b in bloque[1:]:
                s = (s[:-1] + b) if (s.endswith("-") and b[:1].islower()) else (s + " " + b)
            out.append(s)
        else:
            out.extend(bloque)
        bloque.clear()
    for ln in lineas:
        if ln == "":
            vaciar()
            out.append("")
        else:
            bloque.append(ln)
    vaciar()
    return out


def montar_texto(lineas, teatro):
    """Convierte las líneas con marcas en el texto final.
    Teatro: 'NOMBRE: parlamento' al principio de cada turno, separados por línea
    en blanco; los versos siguientes del mismo turno van en líneas propias."""
    out = []
    pend_vacio = False
    ultimo_turno = False
    for ln in lineas:
        if ln.startswith(M1):
            nom, _, resto = ln[1:].partition(M2)
            if out and out[-1] != "":
                out.append("")
            out.append(nom + ":" + (" " + resto if resto else ""))
            ultimo_turno = True
            pend_vacio = False
            continue
        if ln == "":
            pend_vacio = True
            if out and out[-1] != "":
                out.append("")
            ultimo_turno = ultimo_turno  # un hueco no cierra el turno aún
            continue
        # Línea de texto: si el último turno quedó vacío ("NOMBRE:") se pega a él.
        if out and out[-1] == "" and len(out) >= 2 and out[-2].endswith(":") and \
                re.fullmatch(r"[^:]{1,30}:", out[-2]) and ultimo_turno:
            out.pop()
        out.append(ln)
        pend_vacio = False
    texto = "\n".join(out)
    texto = re.sub(r"[ \t]+\n", "\n", texto)
    texto = re.sub(r"\n{3,}", "\n\n", texto)
    return texto.strip("\n")


_SW = frozenset("de la que el en y a los se del las un por con no una su para es al lo como más pero sus le ya o este sí porque esta entre cuando muy sin sobre también me hasta hay donde quien desde todo nos durante todos uno les ni contra otros ese eso ante ellos e esto mí antes algunos qué unos yo otro otras otra él tanto esa estos mucho quienes nada muchos cual poco ella estar estas algunas algo nosotros mi mis tú te ti tu tus ellas nosotras vosotros vosotras os mío mía míos mías tuyo tuya suyo suya nuestro nuestra".split())
_EN = frozenset("the and of to in is was that with for as his her he she it by on at this which from".split())


def es_espanol(t):
    pal = re.findall(r"[a-záéíóúñü]+", t.lower())
    if len(pal) < 40:
        return False
    sw = sum(1 for p in pal if p in _SW) / len(pal)
    en = sum(1 for p in pal if p in _EN) / len(pal)
    return sw >= 0.20 and en < 0.06


def validar_texto(t):
    """Texto limpio razonable: casi todo letras, sin restos de marcado."""
    if len(t) < MIN_DOC:
        return False
    letras = sum(c.isalpha() for c in t)
    if letras < 0.55 * len(t):
        return False
    resto = len(re.findall(r"\{\{|\}\}|\[\[|\]\]|<[a-z/]|&[a-z]+;", t))
    return resto < len(t) / 2000 + 2


# ---------------------------------------------------------------------------
# Wikisource: clasificación de obras
# ---------------------------------------------------------------------------
_TURNO = re.compile(r"^([A-ZÁÉÍÓÚÑÜ][A-ZÁÉÍÓÚÑÜ0-9 ,.'-]{1,29}):(?: |$)", re.M)
_CAT = re.compile(r"\[\[\s*Categor[ií]a\s*:\s*([^\]|]+)", re.I)
_TEATRO = re.compile(r"^(?:Teatro|Comedias|Tragedias|Dramas|Entremeses|Zarzuelas|Sainetes|Autos sacramentales|Obras de teatro)\b|"
                     r"\bTeatro de\b|\bTragedias de\b|\bComedias de\b|\bDramas de\b|^Entremeses", re.I)
_NARR = re.compile(r"^(?:Novelas|Cuentos|Leyendas|Relatos|Episodios Nacionales|Fábulas|Cuento|Novela)\b", re.I)
_POES = re.compile(r"^(?:Poesías|Sonetos|Romances|Odas|Poemas|Coplas|Canciones|Cancionero)\b", re.I)
_LIT = re.compile(r"^Literatura .*\(Títulos\)$|^Obras por capítulos$", re.I)
_EXCL = re.compile(r"Diccionario|Biblia|Reina-Valera|Leyes|Documentos|Sesiones|Tratados|Legislaci|Actas|"
                   r"Constituci|Jurisprudencia|Decretos|Historia de|Biograf|Enciclopedia|Geograf|"
                   r"Organización de las Naciones|Atentado|Traducciones del latín|Lingüística", re.I)
_TIT_NO = re.compile(r"^(?:Elenco|Personas?|Personajes|Reparto|Interlocutores|Índice|Indice|Portada|"
                     r"Dedicatoria|Licencia|Tasa|Aprobaci|Notas?|Nota del editor|Prólogo del editor|"
                     r"Introducci|Biograf|Bibliograf|Anexo|Apéndice|Apendice|Fe de erratas|Erratas)\b", re.I)


def clasificar(cats):
    if any(_EXCL.search(c) for c in cats):
        return None
    if any(_TEATRO.search(c) for c in cats):
        return "teatro"
    if any(_NARR.search(c) for c in cats):
        return "narrativa"
    if any(_POES.search(c) for c in cats):
        return "poesia"
    return None  # ensayo, historia, derecho, diccionarios...: fuera


def procesar_ws(ns0, ns102):
    prefijo = "Página:"
    obras = collections.defaultdict(list)
    for t in ns0:
        obras[t.split("/")[0]].append(t)
    docs = []  # (obra, título, tipo, texto)
    estr = collections.Counter()
    for obra in sorted(obras, key=lambda s: s.encode("utf-8")):
        cats = set()
        for t in obras[obra]:
            cats.update(c.strip() for c in _CAT.findall(ns0[t]))
        tipo = clasificar(cats)
        if tipo is None:
            estr["obras sin tipo/excluidas"] += 1
            continue
        for t in sorted(obras[obra], key=lambda s: s.encode("utf-8")):
            if _TIT_NO.match(t.split("/")[-1]) and t != obra:
                estr["doc descartado por título"] += 1
                continue
            x = ns0[t]
            if "<pages" in x:
                x = expandir(x, ns102, prefijo)
            teatro = tipo == "teatro"
            if teatro:
                x = _marcar_negrita(x)
            x = limpiar_wikitexto(x)
            lin = _normalizar_lineas(x, teatro)
            lin = _unir_prosa(lin)
            texto = montar_texto(lin, teatro)
            if not validar_texto(texto):
                estr["doc descartado: vacío/ruidoso"] += 1
                continue
            if not es_espanol(texto):
                estr["doc descartado: no español"] += 1
                continue
            if teatro:
                turnos = len(_TURNO.findall(texto))
                if turnos < 8 or turnos * 400 < len(texto) * 0.3:
                    # sin diálogo reconocible: no es teatro útil para este corpus
                    estr["teatro sin turnos reconocibles"] += 1
                    continue
            titulo = t.replace("/", " / ")
            docs.append((obra, t, tipo, titulo + "\n\n" + texto + "\n"))
    return docs, estr


def fase_ws(descargas, salida):
    t0 = time.time()
    ns0, ns102 = {}, {}
    n = 0
    for tit, ns, redir, tx in paginas(os.path.join(descargas, "eswikisource.xml.bz2")):
        n += 1
        if ns == 0 and not redir and tx:
            ns0[tit] = tx
        elif ns == 102:
            ns102[tit] = tx
    docs, estr = procesar_ws(ns0, ns102)
    del ns0, ns102
    os.makedirs(os.path.join(salida, "_cache"), exist_ok=True)
    with open(os.path.join(salida, "_cache", "ws.pkl"), "wb") as f:
        pickle.dump((docs, dict(estr)), f, protocol=4)
    tot = collections.Counter()
    for d in docs:
        tot[d[2]] += len(d[3].encode("utf-8"))
    print("ws: %d documentos; bytes %s; descartes %s; %.0f s" % (len(docs), dict(tot), dict(estr),
                                                             time.time() - t0), flush=True)


# ---------------------------------------------------------------------------
# Wikipedia
# ---------------------------------------------------------------------------
_SEC_FUERA = re.compile(r"^(?:Referencias?|Enlaces? externos?|V[ée]ase tambi[ée]n|Bibliograf[ií]a|Notas?|"
                        r"Notas y referencias|Fuentes|Otros proyectos|Lectura adicional|Galer[ií]a|"
                        r"Obras?|Filmograf[ií]a|Discograf[ií]a|Premios?|Enlaces)$", re.I)


def limpiar_wp(x):
    x = limpiar_wikitexto(x, wikipedia=True)
    out = []
    saltar = 0  # nivel de la sección descartada (0 = ninguna)
    for ln in x.split("\n"):
        ln = re.sub(r"[ \t ]+", " ", ln).strip()
        if not ln:
            out.append("")
            continue
        h = re.match(r"^(={2,6})\s*(.*?)\s*\1\s*$", ln)
        if h:
            nivel = len(h.group(1))
            if saltar and nivel > saltar:
                continue
            saltar = nivel if _SEC_FUERA.match(h.group(2)) else 0
            if not saltar:
                out.append(h.group(2))
            continue
        if saltar:
            continue
        if ln[0] in "*#:;|!{}" or ln.startswith(("[[", "----")):
            continue
        if len(ln) < 40 and not ln.endswith("."):
            continue  # restos sueltos (pies, listas cortas)
        out.append(ln)
    t = "\n".join(out)
    t = re.sub(r"\(\s*[,;]?\s*\)", "", t)
    t = re.sub(r" +([,.;:)])", r"\1", t)
    t = re.sub(r"\( +", "(", t)
    t = re.sub(r"[ \t]+\n", "\n", t)
    t = re.sub(r"\n{3,}", "\n\n", t).strip("\n")
    return t


def fase_wp(descargas, salida):
    t0 = time.time()
    docs = []
    estr = collections.Counter()
    for tit, ns, redir, tx in paginas(os.path.join(descargas, "eswiki-trozo.xml.bz2")):
        if ns != 0:
            continue
        estr["páginas ns0"] += 1
        if redir or tx.lstrip().lower().startswith(("#redirec", "#redirect")):
            estr["redirecciones"] += 1
            continue
        if re.search(r"\{\{\s*(?:desambiguaci[óo]n|desambig)", tx, re.I) or tit.startswith(("Anexo:", "Wikipedia:")):
            estr["desambiguación/anexos"] += 1
            continue
        t = limpiar_wp(tx)
        if not validar_texto(t):
            estr["vacío/ruidoso/corto"] += 1
            continue
        if not es_espanol(t):
            estr["no español"] += 1
            continue
        docs.append((tit, tit, "wikipedia", tit + "\n\n" + t + "\n"))
    os.makedirs(os.path.join(salida, "_cache"), exist_ok=True)
    with open(os.path.join(salida, "_cache", "wp.pkl"), "wb") as f:
        pickle.dump((docs, dict(estr)), f, protocol=4)
    print("wp: %d artículos, %d B; %s; %.0f s" % (len(docs), sum(len(d[3].encode("utf-8")) for d in docs),
                                                  dict(estr), time.time() - t0), flush=True)


# ---------------------------------------------------------------------------
# Selección, partición, escritura y estadísticas
# ---------------------------------------------------------------------------
def agrupar(docs):
    """tipo -> {obra: [(título, texto_bytes)]} con los documentos en orden."""
    g = collections.defaultdict(lambda: collections.defaultdict(list))
    for obra, tit, tipo, txt in docs:
        g[tipo][obra].append((tit, txt.encode("utf-8")))
    return g


def tam(obra_docs):
    return sum(len(b) for _, b in obra_docs)


def recortar(obra_docs, limite):
    """Primeros documentos de la obra hasta 'limite' bytes (al menos uno)."""
    out, s = [], 0
    for t, b in obra_docs:
        if out and s + len(b) > limite:
            break
        out.append((t, b))
        s += len(b)
    return out


def elegir(g, pres_prueba, pres_entrena):
    """Devuelve (prueba, entrena): listas de (tipo, obra, [(tit, bytes)])."""
    prueba, entrena = [], []
    for tipo in ("teatro", "narrativa", "poesia", "wikipedia"):
        obras = sorted(g[tipo], key=lambda o: (crc("p:" + o), o))
        acum = 0
        en_prueba = set()
        for o in obras:
            if acum >= pres_prueba[tipo]:
                break
            if tam(g[tipo][o]) > (MAX_OBRA_PRUEBA if tipo != "wikipedia" else 60_000):
                continue
            prueba.append((tipo, o, g[tipo][o]))
            acum += tam(g[tipo][o])
            en_prueba.add(o)
        acum = 0
        for o in sorted(g[tipo], key=lambda o: (crc("e:" + o), o)):
            if o in en_prueba:
                continue
            if acum >= pres_entrena[tipo]:
                break
            docs = recortar(g[tipo][o], MAX_POR_OBRA) if tipo != "wikipedia" else g[tipo][o]
            entrena.append((tipo, o, docs))
            acum += tam(docs)
    return prueba, entrena


def escribir(carpeta, prueba, entrena):
    """Escribe entrena.bin, prueba.bin e indice.bin (formato crear_corpus_ele)."""
    os.makedirs(carpeta, exist_ok=True)
    orden = lambda lst: sorted(lst, key=lambda e: (crc("o:" + e[1]), e[1]))
    grupos = {}
    for nombre, lst in (("entrena", entrena), ("prueba", prueba)):
        docs = []
        for tipo, o, ds in orden(lst):
            for tit, b in ds:
                docs.append(b)
        grupos[nombre] = docs
    import struct
    tabla = bytearray()
    bins = {}
    for nombre in ("entrena", "prueba"):
        blob = b"".join(grupos[nombre])
        bins[nombre] = blob
        with open(os.path.join(carpeta, nombre + ".bin"), "wb") as f:
            f.write(blob)
        desp = 0
        for d in grupos[nombre]:
            tabla += struct.pack("<QQ", desp, len(d))
            desp += len(d)
    cab = [ele.MAGIA, 1, len(grupos["entrena"]), len(grupos["prueba"]),
           len(bins["entrena"]), ele.crc32c(bins["entrena"]),
           len(bins["prueba"]), ele.crc32c(bins["prueba"]), ele.crc32c(bytes(tabla))]
    cab.append(ele.crc32c(struct.pack("<9Q", *cab)))
    cab += [0] * (16 - len(cab))
    with open(os.path.join(carpeta, "indice.bin"), "wb") as f:
        f.write(struct.pack("<16Q", *cab) + bytes(tabla))
    return bins, cab


def bpb(n, tam_comp):
    return 8.0 * tam_comp / n


def compresiones(entrena, prueba):
    r = {}
    gz = lambda b: len(gzip.compress(b, 9, mtime=0))
    xz = lambda b: len(lzma.compress(b, preset=9))
    for nombre, f in (("gzip -9", gz), ("xz -9", xz)):
        solo = f(prueba)
        ent = f(entrena)
        ambos = f(entrena + prueba)
        r[nombre] = (solo, ambos - ent)
    return r


def extracto(b, n=300):
    s = b.decode("utf-8", "replace")
    return s


def fase_armar(salida):
    t0 = time.time()
    with open(os.path.join(salida, "_cache", "ws.pkl"), "rb") as f:
        dws, estr_ws = pickle.load(f)
    with open(os.path.join(salida, "_cache", "wp.pkl"), "rb") as f:
        dwp, estr_wp = pickle.load(f)
    g = agrupar(dws + dwp)
    prueba, entrena = elegir(g, PRESUPUESTO_PRUEBA, PRESUPUESTO_ENTRENA)
    # Desarrollo: prefijo (en el orden por CRC) de lo que entrena en completo.
    por_tipo = collections.defaultdict(list)
    for e in entrena:
        por_tipo[e[0]].append(e)
    desarrollo = []
    for tipo, lst in por_tipo.items():
        acum = 0
        for e in sorted(lst, key=lambda e: (crc("d:" + e[1]), e[1])):
            if acum >= PRESUPUESTO_DESARROLLO[tipo]:
                break
            d = recortar(e[2], 150_000) if tipo != "wikipedia" else e[2]
            desarrollo.append((tipo, e[1], d))
            acum += tam(d)
    salidas = {}
    informe = []
    informe.append("# Corpus en español para ENCA (paso A)\n")
    informe.append("Atribución: Wikipedia en español (CC BY-SA 4.0) y Wikisource en español "
                   "(dominio público), volcados de dumps.wikimedia.org del 1/2-nov-2026.\n")
    for nombre, ent in (("completo", entrena), ("desarrollo", desarrollo)):
        carpeta = os.path.join(salida, nombre)
        bins, cab = escribir(carpeta, prueba, ent)
        salidas[nombre] = (bins, cab, ent)
        print("%s: entrena %d docs %d B CRC32C %08X; prueba %d docs %d B CRC32C %08X"
              % (nombre, cab[2], cab[4], cab[5], cab[3], cab[6], cab[7]), flush=True)
    # Estadísticas
    def resumen(lst):
        d = collections.OrderedDict()
        for tipo in ("teatro", "narrativa", "poesia", "wikipedia"):
            obras = [e for e in lst if e[0] == tipo]
            d[tipo] = (len(obras), sum(len(e[2]) for e in obras), sum(tam(e[2]) for e in obras))
        return d
    for nombre in ("completo", "desarrollo"):
        bins, cab, ent = salidas[nombre]
        informe.append("\n## Juego `%s`\n" % nombre)
        informe.append("| partición | fuente | obras/artículos | documentos | bytes |")
        informe.append("|---|---|---:|---:|---:|")
        for part, lst in (("entrena", ent), ("prueba", prueba)):
            r = resumen(lst)
            tot = sum(v[2] for v in r.values())
            for tipo, (no, nd, nb) in r.items():
                informe.append("| %s | %s | %d | %d | %d |" % (part, tipo, no, nd, nb))
            informe.append("| %s | **total** | %d | %d | %d |" % (part, sum(v[0] for v in r.values()),
                                                              sum(v[1] for v in r.values()), tot))
            ws = sum(v[2] for k, v in r.items() if k != "wikipedia")
            te = r["teatro"][2]
            informe.append("\n%s: Wikisource %d B, Wikipedia %d B; teatro = %.1f%% del total y %.1f%% de Wikisource.\n"
                           % (part, ws, r["wikipedia"][2], 100.0 * te / tot, 100.0 * te / max(ws, 1)))
        informe.append("Bytes: entrena.bin %d (CRC32C %08X), prueba.bin %d (CRC32C %08X); documentos %d + %d.\n"
                       % (cab[4], cab[5], cab[6], cab[7], cab[2], cab[3]))
        comp = compresiones(bins["entrena"], bins["prueba"])
        informe.append("Compresores sobre prueba.bin (%d B), bits por byte:\n" % len(bins["prueba"]))
        informe.append("| compresor | solo | condicional al entrenamiento |")
        informe.append("|---|---:|---:|")
        for k, (solo, cond) in comp.items():
            informe.append("| %s | %.3f | %.3f |" % (k, bpb(len(bins["prueba"]), solo), bpb(len(bins["prueba"]), cond)))
        informe.append("")
        print(nombre, {k: (round(bpb(len(bins['prueba']), a), 3), round(bpb(len(bins['prueba']), b), 3))
                       for k, (a, b) in comp.items()}, flush=True)
    # Personajes y extractos (sobre el juego completo)
    bins, cab, ent = salidas["completo"]
    pers = collections.Counter()
    for tipo, o, ds in ent:
        if tipo != "teatro":
            continue
        for _, b in ds:
            for n in _TURNO.findall(b.decode("utf-8")):
                pers[n] += 1
    informe.append("\n## Los 20 personajes con más turnos (teatro, entrenamiento completo)\n")
    informe.append("| personaje | turnos |")
    informe.append("|---|---:|")
    for n, c in pers.most_common(20):
        informe.append("| %s | %d |" % (n, c))
    informe.append("\nNota: los nombres salen tal como los abrevian las ediciones (ROS., CLAR., D. JUAN).\n")
    informe.append("\n## Extractos (para comprobar la limpieza)\n")
    for tipo, titulo in (("teatro", "Teatro"), ("narrativa", "Novela / cuento"), ("wikipedia", "Wikipedia")):
        elegidos = [e for e in ent if e[0] == tipo]
        e = elegidos[len(elegidos) // 3]
        tit, b = e[2][len(e[2]) // 2]
        s = b.decode("utf-8")
        ini = len(s) // 2
        if tipo == "teatro":  # empieza en el primer turno de diálogo pasada la mitad
            m = _TURNO.search(s, ini)
            ini = m.start() if m else s.rfind("\n", 0, ini) + 1
        else:  # al principio de un párrafo
            ini = s.find("\n\n", ini) + 2 if s.find("\n\n", ini) >= 0 else ini
        cuerpo = s[ini:ini + 330]
        cuerpo = cuerpo.encode("utf-8")[:300].decode("utf-8", "ignore")
        informe.append("**%s** (%s)\n\n```\n%s\n```\n" % (titulo, tit, cuerpo))
    informe.append("\n## Parámetros\n")
    informe.append("Presupuestos de entrenamiento (B): %s. Prueba: %s. Desarrollo: %s. Máximo por obra %d B; "
                   "obras de prueba de Wikisource <= %d B.\n"
                   % (PRESUPUESTO_ENTRENA, PRESUPUESTO_PRUEBA, PRESUPUESTO_DESARROLLO, MAX_POR_OBRA, MAX_OBRA_PRUEBA))
    informe.append("Descartes en Wikisource: %s. En Wikipedia: %s.\n" % (estr_ws, estr_wp))
    with open(os.path.join(salida, "ESTADISTICAS.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(informe))
    print("armar: %.0f s" % (time.time() - t0), flush=True)
    print("\n".join(informe))


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    descargas, salida = sys.argv[1], sys.argv[2]
    fase = sys.argv[3] if len(sys.argv) > 3 else "todo"
    if fase in ("ws", "todo"):
        fase_ws(descargas, salida)
    if fase in ("wp", "todo"):
        fase_wp(descargas, salida)
    if fase in ("armar", "todo"):
        fase_armar(salida)


if __name__ == "__main__":
    main()
