# ELE: backend nativo alternativo sin Rust (experimental)

**Estado:** implementado y probado sobre Linux para el subconjunto descrito.
**No equivale a self-hosting ni a independencia completa de Rust.**
ELE mantiene la extensión de fuente **`.l`** y el nombre oficial **ELE**.

## Qué se añadió

- `tools/ele_c_backend.py`: lector de `ELE-LIR 1` con comprobaciones de versión,
  índices, tipos, aridad, límites y rechazo explícito de instrucciones no
  implementadas. Emite C11 determinista y opcionalmente invoca GCC/Clang.
- `tools/ele_runtime.h`: runtime C11 propio, sin dependencias de Rust ni
  Cranelift; incorpora ownership por movimiento de recursos, destrucción
  recursiva, operaciones de texto y listas, protección de límites y
  aritmética entera comprobada.
- `tools/ele_build.py`: une un **Stage 1 ya compilado** con el backend C;
  fuente `.l` → Stage 1 (`--emit-lir`) → `ELE-LIR 1` → C11 → ejecutable.
  Ninguna parte de este comando invoca `cargo`, `rustc` o Cranelift.
- `examples/native_without_rust.lir`: ejemplo LIR directamente compilable.
- `tests/native_backend/`: pruebas de generación, ejecución, diagnósticos,
  rechazo de LIR inválido y puente de compilación.

El compilador Stage 1 existente **aún se genera inicialmente con Stage 0
(Rust)**, y el protocolo C es un backend alternativo, no un reemplazo del
frontend que ya está escrito en ELE.

## Ejecución rápida

Requisitos para esta ruta: Python 3.10+ y un compilador C11 (GCC o Clang).
Para Windows se recomienda Clang instalado y su entorno de linking válido;
**esta ruta no ha sido probada aquí con MSVC ni con el SDK de Windows.**

Desde la raíz del proyecto:

```bash
python tools/ele_c_backend.py examples/native_without_rust.lir -o ele_demo
./ele_demo    # imprime 42; código de salida 0
```

Para generar C11 portable sin compilarlo:

```bash
python tools/ele_c_backend.py examples/native_without_rust.lir --emit-c ele_demo.c
cc -std=c11 -O2 ele_demo.c -o ele_demo
```

Con un ejecutable **real precompilado** de Stage 1 (`sema-l`):

```bash
python tools/ele_build.py programa.l \
  --stage1 /ruta/al/sema-l \
  --cc clang \
  --keep-lir programa.lir \
  -o programa
```

En PowerShell de Windows, usa el `.exe` ya construido de Stage 1:

```powershell
python .\tools\ele_build.py .\programa.l --stage1 C:\ELE\sema-l.exe --cc clang -o .\programa.exe
```

La generación C es determinista para un mismo archivo LIR. Los archivos
`.lir` no son código fuente `.l`, sino la salida de Stage 1.

## Cobertura verificada en el backend C

| Capacidad | Estado |
| --- | --- |
| Int, Bool, Unit, constantes y comparaciones | Implementado |
| Aritmética i64, controles de overflow y división por cero | Implementado |
| Bloques, saltos, condiciones, funciones y llamadas | Implementado |
| Text UTF-8, `textbuf`, `append`, `print`, `byteat`, `len` | Implementado |
| Structs, campos, lecturas y escrituras tipadas | Implementado |
| Listas con `listlit`, `listpush`, `listreserve`, `len`, `cap`, índices | Implementado |
| Valor propietario, referencias simples, `drop`, `dropfield`, flags | Implementado para subconjunto; depende del borrow checker de Stage 1 |
| LIR con tipos desconocidos, índices inválidos, aridad errónea | Rechazo previo a generación |
| `Float`, enums, `Option`, `Result`, `listpop`, `platform`, `returnref` | **No soportado**: rechazo explícito |
| Regiones, async, concurrente, ABI externo, FFI | **No soportado** |
| Compilar todo el compilador ELE (Stage 2) | **No conseguido** |
| Eliminar Stage 0 como bootstrap | **Pendiente** |

El backend valida tipos, formas e índices que comprende. **No reproduce
aún la totalidad de `cfg::verify` y `drops::verify`** del backend Rust.
Los archivos LIR destinados al backend C deben salir del frontend y borrow
checker de Stage 1. Una LIR arbitraria diseñada para violar la seguridad
podría eludir comprobaciones de lifetimes y aliasing. **No se debe tratar
este backend experimental como un sandbox ni como consumidor seguro de LIR
no confiable.** Las comprobaciones de runtime de límites y movimientos son
una defensa adicional, no una prueba estática equivalente.

El runtime trata recursos propietarios mediante representación dinámica,
por lo que no se espera el rendimiento de Cranelift ni identidad exacta de
layout/ABI con el backend original. Las salidas ejecutables deben comprobarse
contra Stage 0/Cranelift para cada característica antes de afirmar paridad.

## Evidencia obtenida en el entorno de trabajo

- `python -m unittest discover -s tests/native_backend -v`: **12 pruebas
  aprobadas**. Diez cubren el backend C y dos el puente con un Stage 1
  simulado, no con el binario real del proyecto.
- Compilación de C emitido con GCC y Clang en Linux, incluida compilación con
  `-Wall -Wextra -Wpedantic -Werror`.
- Un ejemplo nativo se ejecutó y produjo `42`.
- Se ejecutó el ejemplo simple con AddressSanitizer y UndefinedBehaviorSanitizer
  de GCC; no equivale a cobertura de todo el compilador ni a los sanitizers de
  código generado por Cranelift.
- **Las 398 pruebas Rust anteriores no se ejecutaron de nuevo**: la sesión no
  tiene `cargo`/`rustc` y el ZIP no incluye `.git` ni binarios Stage 1.
  No se afirma que las pruebas de Rust estén verificadas tras estos cambios.
- Este incremento **no modifica el código Rust**, el frontend ELE o la
  gramática; agrega una alternativa independiente de Rust para código LIR.

## Camino restante a independencia total

1. **Restaurar la Fase 8.5**: imports semánticos con identidad, visibilidad,
   tipos entre módulos y spans por archivo, sin concatenación como sustituto.
   Los cambios incompletos de Hermes no están en el ZIP aportado como commits
   reproducibles; necesitan contrastarse con el workspace original si existen.
2. **Ampliar Stage 1** hasta que procese sus 40 fuentes propias: `Option`,
   `Result`, `match`, enums, referencias en agregados, y operaciones faltantes
   realmente usadas; aumentar la cobertura del protocolo y del backend C.
3. **Compilar Stage 2** desde el ejecutable Stage 1 usando únicamente ELE para
   lexer, parser, semántica, ownership, drops y lowering. El backend C puede
   sustituir a Cranelift durante el bootstrap.
4. **Verificar Stage 3** compilado por Stage 2, comparar tests, diagnósticos,
   semántica del LIR y resultados nativos.
5. **Eliminar el puente Python** implementando el emisor/lector C en ELE o
   migrando a otro backend sin Rust. Si el objetivo incluye no depender de
   ningún compilador externo, ELE deberá disponer finalmente de su propio
   emisor de objetos y enlazador o una cadena equivalente.
6. Añadir validación completa de ownership/lifetimes a la frontera de LIR,
   soporte real de Windows x86-64, y pruebas diferenciales y de memoria.

**Definición de éxito:** independencia de Rust significa que compilar las
fuentes del compilador ELE con un compilador ELE ya generado produce otro
compilador ELE, sin usar Cargo, rustc, Cranelift ni componentes escritos en
Rust en la ruta habitual. Esto todavía no está demostrado.
