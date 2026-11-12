# ELE-LIR 1: lowering inicial de Option/Result primitivos

Esta entrega aprovecha el formato **tagged enum** ya validado de ELE-LIR 1,
sin introducir una representación alternativa de enteros ni saltarse la
comprobación del discriminante.

## Alcance exacto

- `Option<Int>`, `Option<Bool>`: `None` se serializa como variante
  unitaria índice 0; `Some(T)` como variante 1 con payload primitivo.
- `Result<Int|Bool, Int|Bool>`: `Ok(T)` es variante 0 y `Err(E)` variante 1;
  ambas tienen un payload primitivo.
- Cada especialización es un enum sintético distinto en el módulo LIR
  (`enum eN`). Los enums nominales del programa mantienen sus índices y
  no se mezclan con los de los tipos genéricos.
- `i variant`, `i disc` e `i payload` se reutilizan sin cambiar su
  sintaxis. El verificador exige que el tipo y el índice del enum correspondan
  exactamente con la especialización. El backend comprueba la variante activa
  antes de leer el payload.
- `Some(42)` permite inferir `Option<Int>`. `None`, `Ok(42)` y
  `Err(true)` requieren un contexto de tipo concreto mediante `let`
  anotado o retorno de función; no se inventa el tipo genérico ausente.

## Límites de seguridad

Este incremento NO incluye `Option<Text>`, `Result<Text,E>`, listas,
structs propietarios, préstamo de payloads ni el operador `?`. Cuando
se requiere mover o soltar un payload propietario, se conserva el rechazo
`L0016`. No se habilitan conversiones implícitas de enum a entero,
lecturas de variantes inactivas ni valores `Option/Result` inventados.

El formato de texto continúa identificándose como `ELE-LIR 1` y las
representaciones sintéticas se anuncian en la sección existente `enums`.
Un compilador que no reconozca los registros de enums seguirá rechazando
esos módulos, como corresponde a un consumidor incompatible.

## Evidencia reproducible

```bash
cargo test -p project-l --test native_builtin_union_l -- --test-threads=1
python3 -m unittest discover -s tests/native_backend -p 'test_stage1_enum_bridge_contract.py' -v
```

El caso positivo compila
`examples/native_option_result_primitive_stage1.l` mediante Stage 1, valida
el LIR generado con el parser/verificador del bootstrap y genera un ELF64 con
el **backend escrito en ELE**. Linux x86-64 ejecuta el ELF y comprueba
el resultado de `main` (50). Los casos negativos exigen que se rechace
`Option<Text>` y el tipo de payload incompatible en `Err`.

No constituye self-hosting ni Stage 2. Stage 0 sigue participando en el
bootstrap; `Result` sin contexto, las variantes propietarias y las
conversiones `?` requieren trabajo posterior.

## Incremento: payloads agregados sin drop (2026-11-12)

`Option`/`Result` aceptan además payloads **sin drop**: `shape` cuyos campos
son, recursivamente, `Int`, `Bool`, otras `shape` sin drop o `choice` cuyas
variantes llevan a lo sumo un `Int`/`Bool` (las de solo variantes unitarias
incluidas). Ejemplo: `Result of[Int, LexError]` con
`LexError { problem: LexProblem, offset: Int }`.

- **Stage 1** (`lir_builtin_union.l`, `lirBuiltinPayloadOk`): el enum
  sintético `eN` declara el payload como `sK`/`eK`; `i variant`, `i disc`
  e `i payload` no cambian de sintaxis. El verificador de Stage 1 exige que
  el payload sea sin drop y del tipo exacto.
- **Movimiento**: ligar un payload no `Copy` en un brazo (`Some(p)`,
  `Err(e)`) MUEVE el escrutinio (como Stage 0): usarlo después es `L0005`, y
  ligar desde un escrutinio prestado (`view`) es `L0005`.
- **Stage 0** (`lir_protocol.rs`, `drop_free`): `payload` acepta `Int`,
  `Bool` o struct/enum recursivamente sin drop; Text, listas, floats y
  ciclos por valor se rechazan.
- **Backend ELE**: las structs pueden nombrar enums declarados después; los
  layouts se calculan tras leer todas las declaraciones (`cfgLayoutDecls`,
  punto fijo; ciclo por valor = 63). Enum = palabra de tag + área de payload
  del tamaño del mayor payload, rellenada con ceros en `i variant`; copia
  por palabras. `i payload` comprueba el tag (salida 126) antes de copiar el
  agregado por layout y **consume** el enum (uso posterior = 57). Payload
  con Text/lista = 82; extracción de agregado desde un `ref` = 89.

Siguen fuera: `Option<Text>`, `Result<_, Text>`, listas, shapes con Text o
listas, `Option`/`Result` anidados, `?` y `List.pop` (L0016).

```bash
cargo test -p project-l --test lir_option_result_aggregate_l -- --test-threads=1
```

`examples/native_option_result_aggregate_stage1.l`: Stage 1 → ELE-LIR →
backend ELE → ELF64; en Linux imprime `42 205 8 156 3` y sale con 158, igual
que `l run` y `l run-lir` de Stage 0.
