# Interpolación Text — implementación y evidencia

Sintaxis: `"Hola {nombre}; resultado: {10 + f(2)}"`. Llaves literales: `{{` y `}}`.
Expresiones internas usan el parser normal; comentarios, paréntesis, llamadas,
strings escapados y otras interpolaciones pueden anidarse. No hay propiedades
todavía en Proyecto L, por lo que siguen rechazadas también dentro de strings.

## Pipeline

1. Lexer con cursor de fuente único: TextStart/TextEnd, segmentos Text,
   InterpolationStart/End y tokens normales con spans originales.
2. AST Interpolate con expresiones ordenadas analizadas por Pratt.
3. Semántica verifica nombres/tipos; Int/Bool/Float/Text convertibles, unit no.
4. LIR Interpolate conserva expresiones tipadas. Plegado puro y exitoso a Text
   estático cuando todo es constante. No evalúa llamadas del usuario.
5. Ownership consulta Text al formatear, pero detecta movimientos dentro de llamadas.
6. Backend construye un Text propietario usando String y Display por parte, en
   orden y una sola vez; sin conversiones a String intermedias por valor. La
   capacidad inicial cubre bytes literales; puede crecer. No hay GC ni dependencias.

El resultado puede almacenarse, pasarse y retornarse; print no tiene lógica especial
para interpolación. Un literal estático sigue sin asignar. Text no Copy conserva
movimientos; Owned libera su buffer normalmente y nunca referencia temporales.

## Pruebas

Suite final: 2 unitarias del lexer + 6 de conformance + 5 de interpolación + 8 de
fase 2 = **21 pruebas, 0 fallos**. `cargo fmt --check` y Clippy con `-D warnings`
pasan. Se mantienen tests anteriores; el negativo de interpolación no soportada
ahora verifica variable desconocida dentro de interpolación.

Nuevos casos nativos: Fibonacci, strings planos/escapados, primitivas, variables,
aritmética, llamadas con efectos observables para demostrar orden/una evaluación,
resultados almacenados/retornados, Text leído antes de moverse, anidamiento,
comentarios, Unicode, loops con Text propietario y reasignación a partir del
valor anterior. Se comprueban stdout, stderr vacío y código 0. Casos inválidos
comprueban causa/categoría/spans; 1500 fuentes malformadas adicionales, profundidad
excesiva y expansión constante limitada. Overflow/división dentro de interpolación
mantienen panic runtime, o diagnóstico si se usan en const.

Fibonacci se compila y ejecuta con:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo run -- run examples/fibonacci.l
```

Salida exacta verificada por el test nativo (incluye newline final):

```text
Fibonacci: 55
```

Backend sigue provisional LIR → Rust → rustc → ejecutable nativo. Esta característica
es parte del frontend/LIR de L, pero no convierte el backend en generador directo.
No hay cambios en la especificación ni afirmaciones de rendimiento medido.
