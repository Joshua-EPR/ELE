# Sistema de Módulos e Imports de Proyecto L

Este documento describe la especificación e implementación del sistema de módulos
locales e imports introducido en `dev/self-hosting-lexer-modules`.

## 1. Sintaxis

Los programas pueden importar módulos locales usando la sentencia `import`:

```l
import helper
import math
import sub.motor
import util; import algo
```

- Cada sentencia `import` importa un módulo local relativo al directorio del archivo actual.
- Los módulos con puntos (e.g. `import sub.motor`) se resuelven reemplazando puntos por separadores de directorio (`sub/motor.l`).
- La sentencia puede terminar con salto de línea o punto y coma `;`.

## 2. Resolución de Rutas y Canonicalización

1. **Resolución relativa**: Cuando `archivo.l` contiene `import helper`, el compilador busca `helper.l` en el mismo directorio que `archivo.l`.
2. **Canonicalización**: Se utiliza la ruta absoluta canónica del sistema de archivos (`std::fs::canonicalize`). Esto previene fallos por comparaciones de cadenas ingenuas ante diferencias de mayúsculas/minúsculas o rutas relativas equivalentes (`./mod.l` vs `mod.l`).
3. **Módulos no encontrados**: Si el archivo no existe en el disco, se emite un error estructurado `L0014: módulo no encontrado: <nombre> (buscado en '<ruta>')`.

## 3. Grafo de Dependencias y Ciclos

1. **Deduplicación (Diamante)**: Si un módulo es importado por múltiples dependencias (e.g., A importa B y C, y ambos importan Comun), el archivo `comun.l` se carga, analiza y compila **exactamente una vez**.
2. **Detección de Ciclos**: El cargador mantiene una pila de módulos en proceso de resolución. Si un módulo A intenta importar directa o indirectamente un módulo que ya está en la pila, se interrumpe la carga y se emite:
   `L0014: ciclo de dependencias detectado: main -> A -> B -> A`.
3. **Orden Topológico**: Las declaraciones de los módulos se consolidan en orden post-orden (dependencias primero, archivo de entrada al final).

## 4. Preservación de Diagnósticos

Cada diagnóstico conserva el nombre del archivo exacto en el que ocurrió mediante el campo `file: Option<String>` en `Diagnostic`, formateando los errores como:
`directorio/modulo.l:linea:columna: codigo [categoria]: mensaje`.

## 5. Compilación del Compilador Self-Hosted

Con la integración de este sistema de módulos, el compilador autónomo `compiler-l` se estructura limpiamente en múltiples archivos:
- `compiler-l/src/main.l`: Punto de entrada CLI, importa `lexer`, `tokens` y `cursor`.
- `compiler-l/src/lexer.l`: Lógica de tokenización, escaneo de texto y rangos.
- `compiler-l/src/tokens.l`: Formateo y emisión de tokens.
- `compiler-l/src/cursor.l`: Interfaz de cursor para el parser.

El script `compiler-l/build-lexer.ps1` compila `src/main.l` directamente mediante `l build src/main.l --backend cranelift`, sin concatenación textual de fuentes.
