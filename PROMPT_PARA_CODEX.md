# Prompt maestro para Codex — Construir el compilador de Proyecto L

Actúa como **ingeniero principal de compiladores, diseñador de lenguajes, ingeniero de sistemas y responsable de calidad**. Tu misión es construir, **no solo planificar**, la primera implementación del nuevo lenguaje **Proyecto L**, cuya **especificación de diseño v1.0** está en `docs/ESPECIFICACION_L_v1.0.md` (incluida junto a este prompt). Usa la especificación como fuente de verdad y registra de forma visible toda ambigüedad que debas resolver.

## Objetivo

Crear desde cero un proyecto compilable, verificable y extensible que comience con un **compilador nativo real** para un subconjunto coherente del lenguaje. La meta de largo plazo es un lenguaje universal (backend, frontend/Wasm, desktop, Android, sistemas, IA). **No afirmes compatibilidad con plataformas que todavía no tienen backend, toolchain, librerías y pruebas.** Tampoco afirmes ser más rápido que Rust antes de demostrarlo con benchmarks reproducibles.

## Fuentes y límites

1. Lee íntegramente `docs/ESPECIFICACION_L_v1.0.md` antes de diseñar o escribir código. Si el archivo no está presente, detente solo en ese bloqueo concreto e informa que necesitas la especificación; **no inventes otro lenguaje diferente**. Si existe un repositorio preexistente, examina su estructura, instrucciones, archivos de configuración y pruebas antes de modificarlo. Nunca borres ni refactorices un proyecto ajeno para sustituirlo por Proyecto L; crea una subcarpeta `project-l/` si el repo contiene algo no relacionado.
2. La implementación inicial del compilador debe escribirse en **Rust estable**. Prefiere un workspace organizado por responsabilidades, sin arquitectura exageradamente fragmentada. Para generación nativa evalúa Cranelift (`cranelift-codegen`, `cranelift-frontend`, `cranelift-module`, `cranelift-object`) y el enlazador disponible en el entorno. Consulta las APIs de las versiones realmente instaladas; no inventes APIs de crates.
3. Introduce un **IR propio tipado** (LIR), aunque sea pequeño al principio, entre análisis semántico y backend. No acoples el parser directamente a código máquina. Implementa parser con Pratt para expresiones y bloques por llaves. Tokens con spans de línea/columna.
4. Emplea dependencias mínimas. Prohíbe `unwrap()`/`expect()` sobre entrada del usuario no confiable y errores de parser como panics del compilador. Verifica `cargo fmt --check`, `cargo clippy` y `cargo test` donde el entorno lo permita.
5. No crees componentes simulados que respondan éxito sin compilar o verificar. Un interpretador de IR para pruebas es válido, pero **no** debe presentarse como generación nativa. Es preferible un núcleo genuinamente operativo y pequeño a cien módulos vacíos.

## Diseño de carpetas sugerido

```text
project-l/
├── Cargo.toml
├── crates/
│   ├── l-cli/              # ejecutable `l`
│   ├── l-lexer/            # tokens, comentarios, literales, spans
│   ├── l-parser/           # AST y Pratt parser
│   ├── l-diagnostics/      # errores y posiciones
│   ├── l-sema/             # símbolos, tipos, chequeos
│   ├── l-ir/               # IR tipado, bloques y control de flujo
│   ├── l-codegen-native/   # backend nativo (Cranelift o similar)
│   └── l-driver/           # pipeline, compilación y enlace
├── runtime/                # runtime mínimo, si es imprescindible
├── docs/
│   ├── ESPECIFICACION_L_v1.0.md
│   ├── GRAMMAR.md
│   ├── SEMANTICS.md
│   ├── BACKEND.md
│   └── IMPLEMENTATION_STATUS.md
├── examples/
│   ├── hello.l
│   ├── arithmetic.l
│   ├── control_flow.l
│   └── invalid/
├── tests/
└── README.md
```

Si una estructura más pequeña permite llegar antes a compilación real sin perder separación de responsabilidades, úsala y justifica por qué.

## Plan obligatorio de ejecución (trabaja realmente en el código)

**Fase 0 — Reconocimiento y contrato.** Inspecciona archivos/toolchain, verifica compatibilidad con las herramientas locales, crea una lista concreta de hitos y un cuadro `Implementado / Parcial / No implementado`. Detecta y documenta contradicciones residuales de la spec en `docs/DECISIONS.md`; no las resuelvas silenciosamente con características inventadas.

**Fase 1 — Lexer y parser.** Implementa tokens, literales, comentarios, palabras clave, saltos de línea/`;`, bloques, `fn`, `let`, `var`, `const` (si viable), llamadas, `if/else`, `while`, `return`, expresiones aritméticas y booleanas, tipos y símbolos, AST con spans. Errores claros para sintaxis inválida. Incluye al menos pruebas de precedencia (`1 + 2 * 3`), comentarios, multilinea, bloques, string y recuperación de errores.

**Fase 2 — Semántica.** Tabla de símbolos y scope léxico, duplicados, inferencia de `Int/Float/Bool/()`; validación de parámetros y return, `let` inmutable frente a `var`, variables desconocidas, condiciones booleanas, aritmética y tipos incompatibles. Si textos/structs no están soportados todavía, recházalos con diagnóstico explícito `feature not implemented`, no los aceptes falsamente.

**Fase 3 — LIR y backend nativo.** Baja el programa tipado a LIR con funciones, bloques, branches, variables y llamadas. Genera objeto y ejecutable de verdad para el target nativo. Implementa `l build archivo.l` y `l run archivo.l`; `l check archivo.l` no debe ejecutar ni enlazar. Si el entorno carece de linker, prueba la generación del objeto y deja evidencia; no declares éxito de build sin enlazado ni éxito de run sin ejecutar. Provee código de salida observables y `print` para lo soportado. Comprueba que `21 * 2` produce `42`.

**Fase 4 — Extensiones semánticas.** Después de tener Fase 3 **realmente operativa**, integra estructuras, inicializadores, arrays fijos, `enum`, `match`, `Option/Result`, `?`, generics, traits y borrow checker. Construye tests que demuestren rechazo de referencias colgantes, double move, mutación inválida, inferencia incorrecta. No uses mecanismos inseguros para aparentar memoria segura.

**Fase 5 — Características avanzadas.** Efectos `!{}` y `@noalloc`, análisis de asignaciones transitivas, `region`, `Shared<T>`, `async/await`, task executor opcional, FFI, perfiles `core/alloc/std`, helpers de herramientas (`fmt`, `test`, `bench`). Solo anuncia una característica cuando exista compilación + ejecución/diagnóstico + tests.

**Fase 6 — Backends adicionales.** Planifica Wasm/WASI, ARM64, freestanding y demás destinos como extensiones posteriores; implementa solo cuando la base nativa sea sólida. No acoples la gramática a una plataforma. Documenta decisiones del backend en `docs/BACKEND.md`.

## Reglas de compatibilidad de sintaxis que no debes cambiar

- `let` inmutable; `var` mutable; `const` en tiempo de compilación.
- `fn f(x: Int) -> Int { ... }`, función de expresión `fn doble(x: Int) -> Int = x * 2`.
- `struct`/`impl`; `fn` y `mut fn` en métodos; `trait`, `enum`.
- `[...]` = array fijo; `List[...]` = lista dinámica; `T?` = `Option<T>`.
- `Result<T,E>`, `Ok`, `Err`, `?`, `match` exhaustivo.
- `&T` compartido; `&mut T` exclusivo. Autopréstamo solo para parámetros `&T` cuando sea no ambiguo, y para receptor de método; `&mut` de argumento de función libre siempre explícito.
- `Int = i64`, `Float = f64`, overflow entero checked en todos los perfiles, sin conversiones numéricas peligrosas implícitas, condiciones estrictamente `Bool`.
- Efectos `!{alloc, io, block, panic}`, `!{}` puro según conjunto rastreado, `@noalloc` transitivo, `unsafe` solo explícito.
- No recolector de basura obligatorio, no herencia de clases, no `any` implícito.
- Terminación por nueva línea o `;`, sin obligar a escribir `;` por línea.

## Casos de aceptación mínimos (implementa fixtures reales)

**Positivos:**

```l
fn doble(x: Int) -> Int = x * 2
fn main() {
    let valor = doble(21)
    print(valor)
}
```

Salida esperada: `42` y exit code 0, si `print` está incluido en el subset implementado.

```l
fn main() {
    var total = 0
    var i = 1
    while i <= 5 {
        total += i
        i += 1
    }
    print(total)
}
```

Salida esperada: `15`.

**Negativos:**

```l
fn main() { let x = 1; x = 2 }  // reasignación prohibida
fn main() { print(noExiste) }    // símbolo no definido
fn main() { if 10 { print(1) } } // no es Bool
fn f(x: Bool) -> Int { return x } // retorno incompatible
```

Cada negativo debe fallar en `l check` con archivo, línea, columna y causa; nunca emitir binario válido.

**Futuras pruebas de conformidad**: `!{}` prohíbe `print`; `@noalloc` rechaza asignación dinámica; referencias locales no retornables; prueba `Result` y patrones exhaustivos; overflow checked no permitido sin efecto `panic` cuando aplique. Marcarlas **pendientes** hasta que estén implementadas.

## Calidad y seguridad

- Los diagnósticos deben indicar localización y causa; en lo posible código como `L0001`. El compilador no debe crashear ante texto mal formado.
- El parser debe soportar `--emit-ast` o equivalente útil para depuración; el driver podría soportar `--emit-ir` cuando LIR funcione.
- Fija una versión de Rust estable y crates coherentes. Trata paths Windows/Linux con `std::path`, sin hardcodear `/`.
- Tests unitarios e integración; CI sencillo si procede; documentación de cómo instalar las herramientas necesarias, especialmente enlazador en Windows.
- Prohíbe prometer «50% más rápido que Rust» sin medir. Cuando haya dos compiladores funcionales para la misma prueba, aporta script de benchmark repetible con baseline Rust Release, registrando tiempos/RAM/binarios.
- El runtime inicial debe ser mínimo, sin GC o framework asíncrono innecesario. No implementes networking, UI ni Android antes de tener la cadena fuente→binario.

## Entregables antes de terminar la sesión

1. Árbol del repositorio creado y los archivos **reales** modificados.
2. Estado de fases y lista precisa de funcionalidades que funcionan y que faltan.
3. Comandos para instalar dependencias, compilar y probar en el entorno actual.
4. Pruebas ejecutadas con resultado literal (no inventado).
5. Ejemplo positivo ejecutado realmente o bloqueo técnico exacto que lo impidió.
6. Próximos 3 hitos de implementación priorizados.

**Instrucción final:** No te limites a generar un plan ni a escribir documentación. Implementa directamente lo máximo que sea viable, mantén el proyecto compilable y sé estricto con lo que funciona realmente. Si el contexto o el tiempo de ejecución no alcanzan para todo, termina con un hito pequeño pero completamente verificado en lugar de presentar la especificación v1.0 como ya implementada.
