# ELEPad

ELEPad es un editor nativo en desarrollo. El código de aplicación y las pruebas están escritos en ELE v2 (`.l`). El compilador portable `ele.exe` de la raíz genera ejecutables PE32+ reales.

## Estado verificado

| Capacidad | Estado | Evidencia |
|---|---|---|
| `Text`, `List[Int]`, módulos, lectura UTF-8, escritura de bytes, argumentos | Disponible y probado | `elepad.exe` y `editor_test.exe` compilados y ejecutados con `ele.exe` |
| Gap buffer, cursor por bytes, búsqueda, inserción y borrado UTF-8 | Disponible con restricciones | Prueba ELE; no hay grafemas ni columnas visuales |
| Entrada interactiva de consola (teclas, Ctrl/Alt/Shift, Unicode, redimensionado, ratón) y restauración del modo | Disponible en `std/io/console.l`; ELEPad aún no la consume | `tests/std/console_input.ps1` (consola real Windows) y `tests/std/console_input.sh` (pty Linux) |
| Importación de bibliotecas compartidas desde ELEPad | Añadida con `--lib`, pendiente de CI | `probes/console_import.l` y pruebas del driver |
| Editor en ventana nativa (Windows) | Implementado, pendiente de CI | `src/gui_test.l` (en proceso) y `tests/elepad/gui.ps1` (ejecutable real); ver «Editor en ventana» |

## Editor en ventana (Windows)

`src/gui.l` abre el archivo en una ventana nativa con el `Window` lineal de
`std.ui.window`. Comparte con el editor de terminal:

- el núcleo (`editor_core.l`);
- la tabla de teclas (`editor_commands.l`; `terminal_dispatch.l` y
  `gui_dispatch.l` solo traducen eventos);
- el guardado (`document_io.l`).

```powershell
.\ele.exe build .\apps\elepad\src\gui.l --lib . --target pe --output .\target\elepad-gui.exe
.\target\elepad-gui.exe .\archivo.l
.\tests\elepad\gui.ps1 -Ele .\ele.exe
```

Lo que hace:

- **Interfaz:** barra de título con indicador de cambios (●), números de
  línea, tabuladores a 4 columnas, scroll horizontal y vertical que siguen
  al cursor, selección resaltada, cursor, y barra de estado con línea y
  columna (o el prompt de búsqueda).
- **Teclado:** los mismos atajos que la terminal: Ctrl+S, Ctrl+Q, Ctrl+Z,
  Ctrl+Y, Ctrl+A, Ctrl+C, Ctrl+X, Ctrl+V, Ctrl+F, Shift+flechas y Escape.
- **Ratón:** clic izquierdo para mover el cursor y rueda para desplazarse.
- **Cerrar:** cerrar la ventana con cambios sin guardar pide una segunda
  confirmación, como Ctrl+Q y Alt+F4. La segunda solicitud debe ser una
  pulsación nueva; mantener la tecla no descarta los cambios. Escape cancela.

Los atajos Ctrl+letra se toman del carácter de control que genera Windows
(WM_CHAR 1..26), no de la tecla pulsada. Así actúan una sola vez, y una
prueba los puede enviar con `PostMessageW` sin simular el estado de Ctrl.
Las unidades 8, 9, 10 y 13 son Retroceso, Tab y Enter.

Pruebas:

- `src/gui_test.l` usa una ventana real y comprueba, leyendo píxeles:
  - el cursor, el texto dibujado y la selección;
  - la columna de un tabulador y el clic convertido en posición;
  - deshacer con WM_CHAR 26, y que el keydown de Ctrl+letra no actúe dos
    veces;
  - el prompt de búsqueda.
- `tests/elepad/gui.ps1` controla el ejecutable desde fuera:
  - editar y guardar (Ctrl+S como WM_CHAR 19);
  - el cierre con cambios necesita dos peticiones y los descarta;
  - Ctrl+Q y Alt+F4 completos, con modificadores, liberación de teclas y
    repetición; Escape cancela la solicitud;
  - compara los bytes del archivo, incluidos BOM y saltos de línea;
  - deshacer hasta el texto guardado permite cerrar con una.

Pendiente en la ventana:

- Ctrl+O y varios documentos;
- portapapeles del sistema (el interno funciona);
- selección arrastrando el ratón;
- grafemas y caracteres anchos;
- DPI alto;
- Linux, que no tiene backend gráfico.

Cada fotograma se redibuja entero; todavía no hay regiones sucias.

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
.\tests\elepad\terminal_console.ps1 -Exe .\target\elepad-terminal.exe -File .\archivo-de-prueba.l
```

Teclas implementadas: caracteres Unicode, Enter, Tab, Backspace, Delete, flechas, Home, End, Page Up y Page Down. Ctrl+S guarda y comprueba por lectura que los bytes publicados coinciden; Ctrl+Q sale, y requiere una segunda pulsación si existen cambios sin guardar.

Edición avanzada (núcleo compartido `editor_core.l`, utilizable también por un futuro frontend gráfico):

| Atajo | Acción |
|---|---|
| Ctrl+Z / Ctrl+Y | Deshacer / rehacer. Los caracteres escritos seguidos forman un solo paso (un espacio o tabulador cierra la palabra); pegar o escribir sobre una selección es un paso. Una edición nueva descarta la rama de rehacer. Volver al estado guardado quita el indicador `*`. |
| Shift+flechas, Shift+Home/End/PgUp/PgDn | Selección con teclado, mostrada en vídeo inverso. Escape la cancela. |
| Ctrl+A | Seleccionar todo. |
| Ctrl+C / Ctrl+X / Ctrl+V | Copiar / cortar / pegar con un portapapeles **interno del proceso**; no es el portapapeles del sistema. |
| Ctrl+F | Modo búsqueda en la barra de estado: escribir la consulta, Enter (o Ctrl+F) selecciona la siguiente coincidencia y vuelve al principio una vez; Escape vuelve a editar. Búsqueda exacta por bytes UTF-8, sin mayúsculas/minúsculas. |

El historial guarda las operaciones (no copias del documento). Si sus bytes superan 32 MiB, se descarta entero y el documento queda marcado como modificado hasta guardar.

Pendiente: Ctrl+O (necesita una primitiva para construir `Text` a partir de bytes, que el lenguaje todavía no expone), portapapeles del sistema, selección con ratón, scroll horizontal, anchura visual de grafemas y caracteres anchos, activación automática de VT en Windows. El renderer actual admite ANSI/VT y asume 80×24 hasta recibir un evento de resize; las columnas cuentan escalares Unicode, sin ancho de grafemas ni caracteres de doble ancho. En Windows, la consola debe tener procesamiento VT habilitado; esta rama todavía no lo activa. El guardado usa `writeBytes`, que no conserva todos los metadatos del archivo. No se promete restauración ante terminación forzada del proceso.

`terminal.ps1` verifica el ciclo nativo con entrada redirigida. `terminal_console.ps1` usa una consola Windows real, inyecta eventos de teclado, edita y guarda el archivo de prueba indicado, y comprueba la restauración del modo de entrada. Use un archivo de prueba desechable: la segunda prueba modifica su contenido.
