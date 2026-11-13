# NEXO v0.3 — registro de validación (2026-11-13)

Base: `main` en `2712a1b` (incluye NEXO v0.2, PR #66, y el arreglo del
fixture de Stage 1, PR #67). Entorno: Windows 10 x86-64, Rust 1.99.1,
toolchain `stable-x86_64-pc-windows-msvc`.

La ejecución del workspace iniciada en la sesión anterior se interrumpió sin
dejar un resultado verificable, así que toda la validación se repitió.

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `cargo fmt --all --check` | sin cambios |
| `cargo clippy --workspace --all-targets -- -D warnings` | sin avisos |
| `cargo test -p ele-nexo -- --test-threads=1` | 141 aprobadas, 0 fallidas |
| `cargo test --workspace --no-fail-fast -- --test-threads=1` | 725 aprobadas, 0 fallidas, 3 ignoradas (microbenchmarks), código de salida 0 |
| `nexo-physical-fuzz 10000` (release) | 4 semillas × 10 000 operaciones sin divergencias |
| `nexo-physical-fuzz 100000` (release) | 4 semillas × 100 000 operaciones sin divergencias (17,9 s) |
| `nexo-physical-bench` (release, 2 corridas) | ver `NEXO_v0.3_BENCHMARKS.md` |

Las 141 pruebas de `ele-nexo` son las 140 anteriores más
`recommit_of_protected_pages_restores_real_access`, añadida en esta revisión.

## Revisión del código físico

* **`unsafe`** solo en `physical/platform/{windows,linux}.rs` (FFI) y en
  `address_space.rs` (copias de bytes y aritmética de punteros). Cada bloque
  tiene su precondición comentada; los rangos se validan (alineación a página,
  contención en la reserva, aritmética comprobada) antes de cada llamada.
  `pool.rs` y `oracle_adapter.rs` no contienen `unsafe`.
* **`SYSTEM_INFO`** coincide con el layout de Win32 en x86-64.
* **Linux**: reserva con `mmap(PROT_NONE)` y recorte de prefijo/sufijo para
  alinear a 64 KiB, sin `MAP_FIXED`; decommit = `madvise(DONTNEED)` +
  `PROT_NONE`, lo que garantiza ceros al reconfirmar.
* **Windows**: verificado en ejecución que `VirtualAlloc(MEM_COMMIT)` sobre
  páginas ya confirmadas y protegidas restaura `PAGE_READWRITE` (antes el
  seguimiento lo suponía sin prueba).
* **Corregido**: `AddressSpace::is_empty` era incoherente con `len()` tras
  `release`.
* `PhysicalPool` no es `Send`/`Sync` (contiene `NonNull`), coherente con C1.
* `HoleToken` es lineal; un hueco perdido lo detecta `close()` como `Leak`.

## Problemas pendientes

1. **Backend Linux no ejecutado localmente.** Solo se compila y ejecuta en el
   CI de Ubuntu; en esta máquina no hay toolchain Linux.
2. **Atomicidad ante fallos del SO en el reclaim.** Si `protect_none` o
   `decommit` fallan dentro de `destroy`/`release_hole`, la destrucción ya se
   aplicó pero la subpágina queda `Committed` con 0 ocupados: el error se
   devuelve, `check_invariants` lo detecta y los accesos posteriores fallan de
   forma controlada (`Inaccessible`), pero el pool no se recupera. La inyección
   de fallos solo cubre `commit`.
3. **Rendimiento**: 5,6–7,5× más lento que `Box` en la ruta caliente y
   44–46× con commit/reclaim en estas corridas; diagnóstico en
   `NEXO_v0.3_BENCHMARKS.md`. Sin optimizar en esta fase, por decisión.
4. **Medición insuficiente**: una sola hebra, sin percentiles, sin aislamiento
   de CPU, sin RSS/working set; las cifras varían hasta 2× entre corridas.
5. **Metadatos duplicados**: la cabecera normativa se mantiene también en
   estructuras Rust (generaciones y bitmaps), lo que duplica memoria y obliga a
   reescribirla entera en cada transición.
6. **`Handle`** expone `slot`/`generation` mutables; falsificarlos solo
   produce `StaleGeneration`, pero conviene cerrarlo antes del port.
7. **Obligaciones formales**: los teoremas T1–T4 y la correspondencia I11 de
   `NEXO_v0.3_FORMAL.md` están enunciados, no demostrados.
8. **Integración en ELE-LIR** (`--memory-model=nexo`): no iniciada; ver
   `NEXO_v0.3_ELE_PORT.md`.
