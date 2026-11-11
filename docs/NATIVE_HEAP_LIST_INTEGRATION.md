# Integración controlada del heap nativo en ELE

Estado: **incremento experimental**, no soporte de heap de usuario en Stage 1.

Este cambio integra en `main` el código probado en los PR #18, #20 y #21, preservando las mejoras de sintaxis `flow`, `shape`, `choose`, `of[T]` y cobertura nominal del PR #19. Los PR originales se fusionaron sobre ramas apiladas, por lo que **mergeado no significaba integrado en main**.

## Qué se integra

- Emisión nativa Linux ELF64/x86-64 de `mmap`/`munmap` con tamaño dinámico validado (1..1048576 bytes).
- Slots de propietario únicos y pruebas de move, doble drop y uso después de mover o liberar.
- Crecimiento y reducción del propietario mediante `mremap` con actualización del puntero solo tras éxito.
- Buffer `Int` de capacidad acotada, con `push`, `read`, `pop`, `drop`, guards de metadatos y crecimiento mediante `mremap`.
- Instrucción x86-64 `AND` para redondeo a páginas; fixtures de ELF y CI Linux que verifica códigos de salida reales.

## Límites de soporte y seguridad

1. **No se genera aún `List of[Int]` automáticamente desde programas de usuario** en Stage 1/ELE-LIR. El emisor del buffer es un módulo de código escrito en ELE invocado por un fixture, no una implementación integral del tipo de lenguaje.
2. Los límites de heap (1 MiB), pruebas de flags de propietario y salida controlada son protecciones experimentales; no prueban seguridad general frente a aliasing, concurrencia, campos propietarios, excepciones o CFG.
3. Los cuatro módulos de heap/buffer incorporados a esta integración se han migrado a la sintaxis canónica ELE v2 (declaraciones `flow`/`shape`, préstamos `view`/`edit`, `when`, `hold`/`change` y genéricos `of[T]`). Otros módulos de Stage 1 todavía conservan alias heredados por compatibilidad de bootstrap: la migración general sigue pendiente (#12).
4. Los ELF emitidos no requieren libc ni runtime Rust, pero **Stage 0 todavía usa Rust/Cranelift para compilar el emisor**. No hay self-hosting ni PE64 Windows.
5. No cerrar la issue #4 ni la #8 hasta contar con pruebas de integración real de tipos, drops de CFG y Stage 2.

## Verificación esperada de CI

Windows/MSVC compila los programas emisores de Stage 1/heap con Stage 0, exporta los ELF Linux; Ubuntu corre contratos Python, Rustfmt y Clippy; Linux x86-64 ejecuta cada ELF y comprueba exactamente el exit status. La CI de esta nueva integración debe terminar verde antes de fusionar.

## Próximo paso de ingeniería

Introducir operaciones tipadas y verificación de `List of[Int]` a lo largo de AST → semántica → ELE-LIR → backend ELE, con fallos antes de acceder a memoria inválida y drops deterministas por arista de CFG. Mantener los fixtures antiguos como pruebas de bajo nivel, no como prueba de integración completa.
