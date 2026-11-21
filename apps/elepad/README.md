# ELEPad

ELEPad es un editor nativo en desarrollo. El código de aplicación y las pruebas están escritos en ELE v2 (`.l`). El compilador portable `ele.exe` de la raíz genera ejecutables PE32+ reales.

## Estado verificado

| Capacidad | Estado | Evidencia |
|---|---|---|
| `Text`, `List[Int]`, módulos, lectura UTF-8, escritura de bytes, argumentos | Disponible y probado | `elepad.exe` y `editor_test.exe` compilados y ejecutados con `ele.exe` |
| Gap buffer, cursor por bytes, búsqueda, inserción y borrado UTF-8 | Disponible con restricciones | Prueba ELE; no hay grafemas ni columnas visuales |
| Entrada interactiva de consola (teclas, Ctrl/Alt/Shift, Unicode, redimensionado, ratón) y restauración del modo | Disponible en `std/io/console.l`; ELEPad aún no la consume | `tests/std/console_input.ps1` (consola real Windows) y `tests/std/console_input.sh` (pty Linux) |
| Importación de bibliotecas compartidas desde ELEPad | Añadida con `--lib`, pendiente de CI | `probes/console_import.l` y pruebas del driver |
| Win32 GUI | No implementado | — |

El gap buffer conserva capacidad libre junto al cursor. La inserción local no copia el documento completo por pulsación. Mover el cursor sobre una región extensa y serializar al guardar sí requieren recorrer bytes. Los límites UTF-8 evitan editar en mitad de un carácter codificado; no se calculan graphemes ni ancho visual. Se conservan los bytes CRLF o LF tal como se cargaron.

## Compilar y verificar en PowerShell

Desde la raíz del proyecto:

```powershell
.\ele.exe build .\apps\elepad\src\editor_test.l --target pe --output .\apps\elepad\editor_test.exe
.\apps\elepad\editor_test.exe .\apps\elepad\test-output.txt
.\ele.exe build .\apps\elepad\src\main.l --target pe --output .\apps\elepad\elepad.exe
.\apps\elepad\elepad.exe .\archivo.l .\copia-nueva.l '// cambio'
```

`elepad.exe` es la utilidad de ciclo de archivos de M1: abre un archivo UTF-8 existente, añade texto al final, escribe una ruta nueva y verifica la reapertura. Rechaza una salida existente. Aún no es un editor interactivo. `writeBytes` no ofrece publicación atómica ni recuperación de una salida parcialmente escrita; por eso la utilidad exige un nombre de salida nuevo.


\`readKey\` sigue siendo una API inexistente: \`probes/keyboard.l\` permanece como prueba negativa (L0001). En la rama P0-A, \`consoleInputMode\`, \`readConsoleEvent\` y \`std/io/console.l\` proporcionan entrada general. Para que una aplicación fuera de \`std/\` importe la biblioteca sin copiarla, el compilador acepta ahora \`--lib\`:

\`\`\`powershell
.\ele.exe build .\apps\elepad\probes\console_import.l --lib . --target pe --output .\target\elepad-console-probe.exe
.\target\elepad-console-probe.exe
\`\`\`

El probe importa \`take std.io.console\`, abre y cierra el lector y verifica el enlace. **Todavía no es ELEPad interactivo**: \`apps/elepad/src/main.l\` sigue siendo la utilidad M1. El siguiente hito M2 debe integrar \`consoleNext\` al núcleo de edición. Tampoco existe una interfaz Win32 GUI verificada.
