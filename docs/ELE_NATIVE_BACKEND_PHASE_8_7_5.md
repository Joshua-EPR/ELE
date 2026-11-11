> La fase 8.7.6 sustituye `native_rt_print.l` por `native_rt.l`, cambia la
> convención de llamada y añade Text; ver
> [ELE_NATIVE_BACKEND_PHASE_8_7_6.md](ELE_NATIVE_BACKEND_PHASE_8_7_6.md).

# Fase 8.7.5 — `print`, funciones sin retorno e Int completo en el backend nativo ELE

Estado: **implementado y ejecutado en Linux x86-64** (2026-11-11). No cierra
el compilador: es un incremento del backend escrito en ELE.

## Qué cambia

Ruta: `programa.l` → Stage 1 (`main_sema --emit-lir`) → ELE-LIR 1 →
`codegen/native_cfg_*.l` → x86-64 → ELF64.

| Elemento | Antes | Ahora |
|---|---|---|
| `i print val <op>` | rechazado (código 31) | Int y Bool; Text y agregados rechazados |
| `result u`, `cu`, `var vN val u` | rechazado (código 44) | funciones Unit, `main` Unit termina con estado 0 |
| Constantes `ci<n>` | solo rango de 32 bits | rango completo de Int (64 bits con signo) |

Archivos: `codegen/native_rt_print.l` (nuevo), `x86_64.l` (`x64NegReg`,
`x64DivUnsignedReg`), `lir_tokens.l` (`nativeDecimal64`, `is_unit`),
`native_cfg_defs.l`, `native_cfg_types.l`, `native_cfg_ir.l`,
`native_cfg_inst.l`, `native_cfg_verify.l`, `native_cfg_emit.l`.

## Runtime de salida

`rtEmitPrintInt` y `rtEmitPrintBool` son rutinas de código máquina generadas
con el codificador x86-64 de ELE. Reciben el valor en RDI y hacen una única
llamada `write(1, …)`. El Int mínimo se imprime bien porque la magnitud se
divide como entero sin signo. Solo se incluyen en la imagen si el programa
imprime: los ELF de programas sin salida conservan sus bytes exactos.

Unit usa el código de tipo interno `-2`. Solo es válido como resultado de
función, como constante `cu` y como variable no parámetro que recibe una
llamada Unit; el resto de comprobaciones lo rechaza por ser negativo.

## Límites reales

- Una escritura corta o fallida no se reintenta ni se notifica.
- `print` de Text, interpolación, Float y agregados sigue sin soporte nativo
  (requiere integrar el heap y Text en esta ruta).
- Siguen vigentes los límites del subconjunto: 2 parámetros, 64 variables,
  32 bloques y 16 funciones por módulo; sin retorno de agregados.
- Solo Linux ELF64. No existe backend PE64.

## Pruebas

`crates/l/tests/native_print_l.rs` (5 pruebas): fuente canónica
`examples/native_print_stage1.l` con salida exacta
(`native_print_stage1.expected`, idéntica a la de Stage 0), los ejemplos
oficiales `arithmetic`, `hello`, `control_flow` y `loops`, constantes en los
extremos de Int y seis rechazos (`examples/native_cfg_print_*.lir`,
`native_cfg_unit_*.lir`, `native_cfg_const_overflow.lir`).

## Stage 1 en hosts que no son Windows

`tests/stage1_support::build` construye Stage 1 con el backend de referencia
(rustc) cuando el host no es Windows, porque Cranelift de Stage 0 solo genera
para Windows x86-64. Las compilaciones con `--trace-alloc` siguen exigiendo
Cranelift. Resultado medido en Linux con Rust 1.97 y `--ignore-rust-version`:
de 141 a 253 pruebas aprobadas, ningún objetivo empeora. Las 243 restantes
invocan Cranelift o `link.exe` y solo pueden pasar en Windows.

Reproducir:

```bash
cargo build
cargo test -p project-l --test native_print_l
L=target/debug/l
$L build compiler-l/src/main_sema.l && $L build compiler-l/src/native_cfg_demo.l
B=target/x86_64-unknown-linux-gnu/debug
$B/main_sema examples/native_print_stage1.l --emit-lir > /tmp/p.lir
$B/native_cfg_demo /tmp/p.lir /tmp/p.elf && chmod +x /tmp/p.elf && /tmp/p.elf
```
