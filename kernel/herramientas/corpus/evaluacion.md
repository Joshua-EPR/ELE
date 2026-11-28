# Protocolo de evaluación de ENCA (Fase 4)

Fija cómo se mide cada checkpoint para que los números de distintos días
sean comparables. Lo implementa el hito 24; este archivo es la especificación.

## Datos

- Corpus producido por `preparar.ps1` (hito 23): `entrena.bin` (98 %),
  `valida.bin` (1 %), `prueba_sellada/prueba.bin` (1 %).
- **La prueba no se toca hasta el final de la fase.** Todo ajuste (umbrales,
  hiperparámetros, elección de checkpoint) se hace con `valida.bin`. La
  prueba se usa una sola vez, con el checkpoint elegido, para el número final.
- Los números solo se comparan entre checkpoints entrenados con el mismo
  `entrena.bin` (mismo CRC32C en `ESTADISTICAS.md`).

## 1. Bits por byte en validación

Métrica principal: `bits/byte = (sum_i -log2 P(byte_i | contexto)) / bytes`,
con la probabilidad que da la mezcla de ENCA (la misma que se usa para
generar).

Reglas de medida:

1. Se recorre `valida.bin` documento a documento, con los límites del
   índice (`valida.idx`, formato ELEIDX01: desplazamiento y longitud).
2. El contexto se reinicia al empezar cada documento (cada documento es
   independiente: así no depende del orden ni de lo que hubiera antes).
3. Se cuentan todos los bytes del documento, incluido el primero (con el
   contexto vacío) y el salto de línea final.
4. **La validación no se aprende**: la evaluación no modifica el modelo. Si
   el modelo actualiza memorias al evaluar (hipocampo, ventana), se evalúa
   sobre una copia o se restaura el estado al terminar.
5. Se informa también: bytes, documentos, y bits/byte por tipo de documento
   (`valida.tipos`: 0 TEXTO, 1 DIALOGO) cuando haya diálogos en validación.
6. La suma se hace con la misma precisión en todos los checkpoints (el
   kernel usa el logaritmo de la mezcla en f32/f64 que ya usa en
   `espanol.l`); no se cambia entre checkpoints.

## 2. Generaciones fijas

Archivo de prompts: `prompts_es.txt` (20 líneas, UTF-8, un prompt por línea).

- Líneas 1 a 10: comienzos de frase en español (texto corrido). El modelo
  continúa a partir del último byte del prompt, sin salto de línea.
- Líneas 11 a 20: diálogo con formato `TÚ: ...`. El prompt que se da al modelo
  es la línea más `\nENCA:` (así acaban las líneas de turno en el corpus de
  diálogos); la respuesta es lo que el modelo escribe hasta el primer `\n`.

Muestreo (fijo; sin depender del reloj):

| parámetro | valor |
|---|---|
| semilla PCG32 | 4242 (se vuelve a sembrar con 4242 en cada prompt) |
| temperatura | 0,5 |
| top-k | 0 (desactivado) |
| top-p | 1,0 (desactivado) |
| penalización de n-gramas | la de defecto de `enca/muestreo.l` (`mzDefecto`) |
| longitud máxima | 300 bytes por generación (texto); 300 o primer `\n` (diálogo) |

Con la misma semilla, los mismos pesos y el mismo prompt, la salida es la
misma (propiedad de `enca/muestreo.l`): dos ejecuciones del mismo checkpoint
dan archivos idénticos.

## 3. Qué guarda el kernel en cada checkpoint (hito 24)

Para cada checkpoint con número de paso `N` (bytes de entrenamiento vistos),
en la partición de datos, carpeta `eval/`:

- `eval/ckpt_<N>.txt`, texto UTF-8:

```
ENCA evaluación
checkpoint: <N> bytes de entrenamiento
corpus: entrena CRC32C <hex>, valida CRC32C <hex>
valida: <bytes> bytes, <documentos> documentos
bits/byte: <x,xxxx>
bits/byte TEXTO: <x,xxxx>
bits/byte DIALOGO: <x,xxxx>
muestreo: semilla 4242, T 0,5, top-k 0, top-p 1,0, longitud 300
--- generacion 01 (texto)
PROMPT: <línea 1 de prompts_es.txt>
<bytes generados>
--- generacion 02 (texto)
...
--- generacion 20 (dialogo)
PROMPT: TÚ: ¿...
ENCA: <bytes generados>
```

  Las 20 generaciones van en el mismo archivo, en el orden de
  `prompts_es.txt`. Los bytes generados se escriben tal cual (pueden no ser
  UTF-8 válido: es información útil). Un archivo por checkpoint; nunca se
  sobrescribe uno anterior.
- Una línea por checkpoint en `eval/historial.csv`:
  `paso,bits_byte_valida,bytes_valida,crc_entrena,crc_valida`.
- La prueba sellada no se evalúa en ningún checkpoint intermedio.

## 4. Referencias de compresión (sobre `valida.bin`)

Sirven de suelo comparable: un modelo que no gane a `xz -9` en valida no
aprende estructura que un compresor genérico no encuentre.

El usuario pasará sus números con las herramientas del sistema; se anotan
aquí. Para comprobarlos hay un script de Python (Windows):

```
python -I kernel\herramientas\corpus\referencia_compresion.py <salida>\valida.bin --por-documento <salida>\valida.idx
```

| compresor | bytes comprimidos | bits/byte | quién lo midió |
|---|---|---|---|
| gzip -9 | (pendiente) | (pendiente) | usuario |
| xz -9 | (pendiente) | (pendiente) | usuario |
| gzip -9 por documento | (pendiente) | (pendiente) | script |
| xz -9 por documento | (pendiente) | (pendiente) | script |

Los dos primeros valores (archivo entero) deben coincidir con los de la
línea de comandos a unos pocos bytes. Las filas "por documento" son la
referencia justa para un modelo que reinicia el contexto en cada documento.

Comprobación hecha en el hito 23 sobre un `valida.bin` del corpus de
prueba (529 839 bytes, 19 documentos): `gzip -9` CLI 197 990 B (2,9895
bits/byte) frente a Python 198 013 B (2,9898); `xz -9` CLI 169 288 B frente
a Python 169 280 B. No son cifras del corpus de la fase.

## 5. Lo que cambia el hito 24 en el kernel

Ver `kernel/docs/bitacora.md` (Fase 4, hito 23): el kernel actual solo lee
`es/{entrena,prueba,indice}.bin`. Con la salida de `preparar` se puede probar
sin tocar el kernel copiando `entrena.bin` y `indice.bin` a `es/` y
`valida.bin` como `es/prueba.bin` (el índice combinado `indice.bin` lo
describe así); el kernel entonces llama "prueba" a lo que aquí es validación.
El hito 24 debe leer `valida.idx`/`valida.tipos` y escribir `eval/`.
