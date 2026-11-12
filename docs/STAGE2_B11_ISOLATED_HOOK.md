# B11: gancho aislado Stage 1 → LIR → ELF64 (NO Stage 2 pleno)

## Qué prueba y qué no

`crates/l/tests/stage2_hook_l.rs` inicia el **Stage 1 realmente escrito
en ELE** (`main_sema`) y el **backend ELF64 escrito en ELE**
(`native_cfg_demo`) mediante rutas absolutas. Stage 0 solo se ejecuta
**antes**, para construir esas dos herramientas de bootstrap y, en el corpus
simple, como oráculo fuera del recorrido aislado.

El caso de entrada real es `compiler-l/src/flow_self_harness.l`, que importa
`flow_cfg.l` y ejecuta funciones originales de ese módulo. La prueba:

1. Invoca Stage 1 con `--emit-lir` y sin PATH ni variables `RUSTC/CARGO`.
2. Rechaza salidas sin cabecera `ELE-LIR 1`.
3. Pasa el archivo al backend ELE y exige una **imagen ELF64 nueva** con
   cabecera válida (borra la salida anterior para impedir falso éxito).
4. En Linux x86-64 ejecuta la imagen; su estado esperado es **2**.
5. Compara, por separado, dos fuentes fijas aceptadas/rechazadas entre
   `project_l::check` (Stage 0) y `main_sema --check-ownership` (Stage 1),
   exigiendo también el mismo código diagnóstico del caso rechazado.
6. En Linux, si está disponible `strace`, inspecciona `execve/execveat`:
   solo se admite el proceso Stage 1 (o el backend ELE) observado.
   Una invocación de compilador Rust, CLI o subprocess adicional **falla**.
   En CI Linux `ELE_REQUIRE_STRACE=1` exige la herramienta: no se omite.

La comprobación de subprocess no demuestra por sí sola que el ELF resultante
pueda recompilar todo `compiler-l/src`. El Stage 1 generado todavía depende
de Stage 0 para el bootstrap y no recompila sus propias fuentes como binario
completo. **No se debe denominar Stage 2 ni self-hosted a este incremento.**

## Reproducción

Desde la raíz del repositorio:

```powershell
cargo test -p project-l --test stage2_hook_l -- --test-threads=1
```

En Ubuntu, con `strace` instalado, exigir el guard de procesos:

```bash
ELE_REQUIRE_STRACE=1 cargo test -p project-l --test stage2_hook_l -- --test-threads=1
```

Windows valida la emisión y los códigos de error; Linux x86-64 además ejecuta
ELF64 y vigila la creación de procesos. El flujo permanece **fuera** de la
lógica de compilación: los tests están escritos en Rust para instrumentar el
bootstrap y no forman parte de la toolchain final.

## Próximos requisitos antes de Stage 2 pleno

- Resolver B1–B9 restantes de autocobertura del núcleo.
- Recompilar el propio `main_sema.l` y sus dependencias con Stage 1, no solo
  el `flow_self_harness.l`.
- Ejecutar el nuevo compilador resultante y repetir compilación y suite.
- Validar los rechazos de memoria, LIR y ABI y las rutas de plataforma soportadas.
