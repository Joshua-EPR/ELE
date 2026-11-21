# ELEPad: estado de implementación (2026-11-21)

Base de este trabajo: `origin/main` en `b9f6877` (PR #134 fusionado). La rama de trabajo es `codex/elepad-core-20261121`. El `main` del árbol principal tiene cambios preparados y un conflicto en `.gitignore`; no se modificó.

## Dependencias

| Fase | Dependencia técnica | Estado |
|---|---|---|
| P0-E editor de terminal | Entrada `std/io/console.l`, motor de edición, salida de terminal, guardado seguro | EN DESARROLLO: entrada disponible; motor parcial; faltan salida, comandos y guardado |
| P0-B archivos nativos | Recursos con ownership, operaciones de bloques, flush, reemplazo seguro en PE64 y ELF64 | NO INICIADO: solo `readText` y `writeBytes` de archivo completo |
| P0-C Win32 y callbacks | Contrato FFI tipado, verificación LIR, ABI Win64, duración de callbacks | NO INICIADO: llamadas internas a Win32 no son una API de ELE |
| P0-D ventanas | P0-C, `WndProc`, eventos y recursos de ventana | NO INICIADO |
| M3 ELEPad gráfico | P0-D, P0-B y motor compartido con P0-E | NO INICIADO |

## Avance verificable en esta rama

- `apps/elepad/src/buffer.l`: borrado hacia atrás por escalar UTF-8 y borrado de CRLF como unidad.
- `apps/elepad/src/cursor.l`: navegación izquierda/derecha que salta CRLF, actualización de columna tras movimiento horizontal, fin visible de línea antes del CR.
- `apps/elepad/src/editor_test.l`: pruebas deterministas de esos casos y del ciclo de archivo existente.
- Windows: Stage 0 reconstruido con `cargo build -p project-l --bin l`; este compiló `compiler-l/src/main_driver.l` con Cranelift. El driver generado compiló `editor_test.l` a PE64 y el ejecutable terminó con `elepad-core-ok` y código 0.

No se ejecutaron todavía pruebas interactivas, de Linux, GUI, CI ni fixpoint Gen 2 → Gen 3 para esta rama. Ninguna fase está completada.

## Continuación concreta

1. Añadir salida de terminal controlada y prueba de consola real; construir un bucle de eventos que reutilice `std.io.console` y el buffer. Mantener pruebas deterministas con eventos inyectados.
2. Definir y verificar recursos opacos de archivo antes de exponer handles; implementar lectura/escritura por bloques y publicación segura en ambas plataformas.
3. Extender la LIR y el backend PE64 con llamadas externas y callbacks de firmas admitidas explícitamente, con pruebas negativas y ejecución real de `WndProc`.
4. Implementar ventanas, renderizado y ELEPad gráfico sobre el mismo núcleo; después medir, auditar y ejecutar el bootstrap completo y el fixpoint.

La rama principal de trabajo debe permanecer separada del `main` local con conflicto. Los PR posteriores deben basarse en la dependencia implementada y validada; no hay orden de fusión adicional hasta que existan esas ramas.
