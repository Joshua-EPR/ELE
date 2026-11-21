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

El núcleo también borra hacia atrás un escalar UTF-8 completo y trata CRLF como un solo salto de línea al navegar o borrar. `lineEnd` sitúa el cursor antes del CR de una línea CRLF. Estas operaciones están cubiertas por `editor_test.l`; el programa principal continúa siendo la utilidad M1, sin bucle interactivo ni guardado atómico.

## Compilar y verificar en PowerShell

Desde la raíz del proyecto:

```powershell
.\ele.exe build .\apps\elepad\src\editor_test.l --target pe --output .\apps\elepad\editor_test.exe
.\apps\elepad\editor_test.exe .\apps\elepad\test-output.txt
.\ele.exe build .\apps\elepad\src\main.l --target pe --output .\apps\elepad\elepad.exe
.\apps\elepad\elepad.exe .\archivo.l .\copia-nueva.l '// cambio'
```

`elepad.exe` es la utilidad de ciclo de archivos de M1: abre un archivo UTF-8 existente, añade texto al final, escribe una ruta nueva y verifica la reapertura. Rechaza una salida existente. Aún no es un editor interactivo. El `writeBytes` nativo actual escribe a un temporal en el directorio de destino, sincroniza y publica mediante renombrado/reemplazo; todavía no conserva de forma completa permisos y atributos ni ofrece una API de archivos por bloques. La utilidad exige una salida nueva para evitar sobrescrituras accidentales.

`readKey` sigue siendo una API inexistente: `probes/keyboard.l` permanece como prueba negativa (L0001). En la rama P0-A, `consoleInputMode`, `readConsoleEvent` y `std/io/console.l` proporcionan entrada general. Para que una aplicación fuera de `std/` importe la biblioteca sin copiarla, el compilador acepta ahora `--lib`:

```powershell
.\ele.exe build .\apps\elepad\probes\console_import.l --lib . --target pe --output .\target\elepad-console-probe.exe
.\target\elepad-console-probe.exe
```

El probe importa `take std.io.console`, abre y cierra el lector y verifica el enlace. `apps/elepad/src/main.l` sigue siendo la utilidad M1; `apps/elepad/src/terminal.l` es el editor de terminal de esta rama. No existe una interfaz Win32 GUI verificada.

## Editor de terminal (rama P0-E)

`src/terminal.l` abre un archivo UTF-8 existente y procesa eventos de `std.io.console` sin sondeo. El documento y el cursor viven en `editor_core.l`; `terminal_dispatch.l` traduce teclas a operaciones compartidas, y `terminal_render.l` construye salida ANSI/VT en bytes. Compilación desde la raíz con el driver autónomo que incluya `writeConsoleBytes`:

```powershell
.\ele.exe build .\apps\elepad\src\terminal.l --lib . --target pe --output .\target\elepad-terminal.exe
.\target\elepad-terminal.exe .\archivo.l
.\tests\elepad\terminal.ps1 -Ele .\ele.exe
```

Teclas implementadas: caracteres Unicode, Enter, Tab, Backspace, Delete, flechas, Home, End, Page Up y Page Down. Ctrl+S guarda y comprueba por lectura que los bytes publicados coinciden; Ctrl+Q sale, y requiere una segunda pulsación si existen cambios sin guardar. Los demás atajos siguen pendientes. El renderer actual admite ANSI/VT y asume 80×24 hasta recibir un evento de resize; las columnas cuentan escalares Unicode, sin ancho de grafemas ni caracteres de doble ancho. En Windows, la consola debe tener procesamiento VT habilitado; esta rama todavía no lo activa. El guardado usa `writeBytes`, que no conserva todos los metadatos del archivo. No se promete restauración ante terminación forzada del proceso.
