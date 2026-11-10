# Paridad Léxica: Strings, Escapes e Interpolación

Este documento formaliza la paridad léxica entre el lexer de referencia de Stage 0
(`crates/l/src/lexer.rs`) y el lexer autónomo escrito en Proyecto L (`compiler-l/src/lexer.l`).

## 1. Tipos de Tokens y Cobertura

El lexer en L emite `LexToken` con `kind: LexKind`, `start: Int` y `end: Int` (rangos de byte semiabiertos `[start, end)`):

| Token | LexKind en L | Representación Stage 0 | Significado |
|---|---|---|---|
| `Word` | `LexKind.Word` | `Kind::Word(String)` | Identificadores y palabras reservadas |
| `Integer` | `LexKind.Integer` | `Kind::Int(i64)` | Literales decimales enteros |
| `Symbol` | `LexKind.Symbol` | `Kind::Sym(String)` | Operadores y delimitadores |
| `Newline` | `LexKind.Newline` | `Kind::Newline` | Salto de línea (`\n`) |
| `Eof` | `LexKind.Eof` | `Kind::Eof` | Fin de archivo (rango `[end, end)`) |
| `Text` | `LexKind.Text` | `Kind::Text(String)` | Literal de texto simple o fragmento de interpolación |
| `TextStart` | `LexKind.TextStart` | `Kind::TextStart` | Comillas de apertura `"` en texto interpolado |
| `TextEnd` | `LexKind.TextEnd` | `Kind::TextEnd` | Comillas de cierre `"` en texto interpolado |
| `InterpolationStart` | `LexKind.InterpolationStart` | `Kind::InterpolationStart` | Llave de apertura `{` en texto interpolado |
| `InterpolationEnd` | `LexKind.InterpolationEnd` | `Kind::InterpolationEnd` | Llave de cierre `}` en texto interpolado |

## 2. Sintaxis y Escapes de Texto

- **Delimitadores**: Las cadenas comienzan y terminan con comillas dobles `"`.
- **Escapes simples**: `\n` (salto de línea), `\t` (tabulación), `\r` (retorno de carro), `\"` (comillas dobles), `\\` (barra invertida).
- **Escapes Unicode**: `\u{HEX}` con 1 a 6 dígitos hexadecimales. Se valida que el valor no supere `0x10FFFF` y que no caiga en el rango de surrogates `0xD800..=0xDFFF`.
- **Llaves literales**: `{{` produce `{` y `}}` produce `}` sin iniciar ni cerrar interpolaciones.
- **Interpolación**: Una llave aislada `{` abre una interpolación. Se emiten `TextStart`, el fragmento `Text` previo, `InterpolationStart`, los tokens internos analizados por el lexer estándar, y al encontrar `}` al nivel cero de anidamiento de llaves, se emite `InterpolationEnd`. Al cerrar las comillas se emiten el fragmento `Text` final y `TextEnd`.
- **Anidamiento**: Se admite anidamiento de cadenas e interpolaciones hasta una profundidad de 64 niveles.

## 3. Diagnósticos y Errores Léxicos

| Problema | Mensaje en Stage 0 / Driver L | Offset reportado |
|---|---|---|
| `UnclosedString` | `cadena sin cerrar` | Offset de comilla inicial `"` |
| `InvalidEscape` | `escape no implementado o inválido` | Offset de barra `\` |
| `InvalidUnicodeEscape` | `escape Unicode inválido` | Offset de barra `\` |
| `InvalidUnicodeScalar` | `scalar Unicode inválido` | Offset de barra `\` |
| `UnclosedInterpolation` | `interpolación sin cerrar: falta '}'` | Offset de llave inicial `{` |
| `UnopenedBrace` | `llave '}' sin apertura en Text; use '}}' para una llave literal` | Offset de llave `}` |
| `ExcessiveDepth` | `límite de anidamiento Text (64) excedido` | Offset de comilla inicial `"` |
| `UnclosedComment` | `comentario sin cerrar` | Offset de inicio `/*` |
| `UnsupportedNumber` | `literal de punto flotante fuera del subconjunto léxico` | Offset inicial del número |
| `UnexpectedByte` | `carácter inválido o fuera del subconjunto léxico` | Offset del byte |

## 4. Cursor de Tokens (`compiler-l/src/cursor.l`)

Provee la interfaz que consumirá el futuro parser:
- `cursorNew(fileId: Int) -> TokenCursor`
- `cursorIsAtEnd(cursor: &TokenCursor, tokens: &List<LexToken>) -> Bool`
- `cursorCurrent(cursor: &TokenCursor, tokens: &List<LexToken>) -> &LexToken`
- `cursorCurrentKind(cursor: &TokenCursor, tokens: &List<LexToken>) -> &LexKind`
- `cursorAdvance(cursor: &mut TokenCursor, tokens: &List<LexToken>) -> &LexToken`
- `cursorExpect(cursor: &mut TokenCursor, tokens: &List<LexToken>, expected: &LexKind) -> Bool`
