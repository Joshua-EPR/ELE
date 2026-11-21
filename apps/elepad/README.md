# ELEPad

ELEPad es un editor nativo en desarrollo. El código de aplicación y las pruebas están escritos en ELE v2 (`.l`). El compilador portable `ele.exe` de la raíz genera ejecutables PE32+ reales.

## Estado verificado

| Capacidad | Estado | Evidencia |
|---|---|---|
| `Text`, `List[Int]`, módulos, lectura UTF-8, escritura de bytes, argumentos | Disponible y probado | `elepad.exe` y `editor_test.exe` compilados y ejecutados con `ele.exe` |
| Gap buffer, cursor por bytes, búsqueda, inserción y borrado UTF-8 | Disponible con restricciones | Prueba ELE; no hay grafemas ni columnas visuales |
| Entrada interactiva de consola (teclas, Ctrl/Alt/Shift, Unicode, redimensionado, ratón) y restauración del modo | Disponible en `std/io/console.l`; ELEPad aún no la consume | `tests/std/console_input.ps1` (consola real Windows) y `tests/std/console_input.sh` (pty Linux) |
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

`readKey` nunca fue una API: `probes/keyboard.l` sigue siendo rechazado a propósito (L0001). La capacidad general ya existe como operaciones de plataforma del compilador (`consoleInputMode`, `readConsoleEvent`) y la biblioteca `std/io/console.l` (ver `std/README.md`). El siguiente bloqueo para M2 es que el cargador de módulos solo resuelve `take` relativo al archivo importador: ELEPad no puede importar `std/io/console.l` hasta que exista una raíz de bibliotecas. La interfaz gráfica tampoco se ha ejecutado.
