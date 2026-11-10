# ELE — Fase 8.5: avance parcial de imports semánticos

**Estado:** cambios de implementación en Stage 1 pendientes de validar con el
compilador Windows/MSVC. **No es una fase terminada, no hay Stage 2**.

## Base revisada

- Fuente aportada: `ELE-proyecto-actualizado(1).zip` (sin directorio `.git`).
- El ZIP trae Stage 0 en Rust, Stage 1 en archivos `.l`, backend C11
  experimental que se construye con Python/GCC/Clang y pruebas de referencia.
- No hay ejecutable Stage 1 precompilado ni `cargo`/`rustc` en el entorno de
  revisión. No es posible afirmar que los cambios `.l` compilen todavía.
- Se ejecutó la suite Python del backend experimental (12 pruebas anteriores
  y 4 nuevas de auditoría de fuentes; 16 aprobadas), que **no sustituye**
  la suite Rust ni las pruebas nativas MSVC.

## Cambios de código en Stage 1

- `compiler-l/src/module_graph_l.l`: matriz explícita de acceso transitivo
  a imports, calculada en orden topológico tras la carga de módulos. El
  símbolo propio sigue siendo visible sin `pub`; un símbolo externo requiere
  `pub` **y** una relación de import real desde el módulo consumidor.
- `modules_l.l`: captura aristas directas para cada módulo, identifica
  dependencias cargadas, elabora la matriz y evita un segundo lexing del
  texto concatenado: rebasa los tokens del lexer por archivo a offsets
  compatibles con el AST heredado.
- `symbols.l`, `scopes.l`, `sema_context.l`, `main_sema.l` y resolutores de
  expresiones: propagan el contexto modular y devuelven error `L0014` si dos
  declaraciones públicas importadas tienen el mismo nombre no calificado.
  Los nombres locales prevalecen sobre los importados.
- `sema.l`: registra structs y enums **antes** de resolver firmas, eliminando
  la dependencia textual del orden de las declaraciones de tipo.
- `crates/l/tests/modules_l.rs`: añade cinco escenarios de integración:
  diamante transitivo, símbolo de módulo hermano no importado, ambigüedad
  pública, tipos públicos homónimos y uso de tipo declarado posteriormente.
  Estas cinco pruebas **no se ejecutaron aquí**.

## Auditoría estática de autocobertura (fase 8.6, solo inventario)

`python tools/ele_source_audit.py --json docs/stage1-static-module-inventory.json`

Resultado del árbol actualizado:

- 43 archivos `.l` bajo `compiler-l/src`.
- 40 alcanzables desde `main_sema.l`.
- 3 que no pertenecen al grafo de imports de ese punto de entrada.
- 228 aristas de import entre los módulos alcanzables.
- Cero imports inexistentes y cero ciclos detectados mediante búsqueda
  estática (no equivale a la validación de import de Stage 1).

El auditor es una **herramienta temporal de desarrollo escrita en Python**.
No forma parte del compilador, del backend ni del runtime de ELE y no debe
convertirse en dependencia de producción.

## Límites que impiden cerrar la fase 8.5

1. **El AST conserva offsets en una fuente combinada.** Aunque ya se retokeniza
   por archivo, el compilador aún mantiene un buffer combinado para spans y
   comparación de nombres. No se ha eliminado definitivamente la concatenación.
2. El sistema actual de rutas usa conversiones ASCII byte-a-byte; la resolución
   de imports dentro de directorios con nombres UTF-8 no ASCII necesita una
   API de slicing de Text que preserve bytes Unicode.
3. No hay acceso aquí a un compilador Stage 0 operativo en Windows/MSVC;
   deben compilarse `module_graph_l.l`, el cargador y el frontend real.
4. Se deben validar las funciones y tipos cruzando múltiples módulos con
   ownership, drops, emisión LIR y ejecutables nativos; las pruebas ya
   presentes más las nuevas están preparadas para ese entorno.
5. La construcción de un compilador Stage 2/Stage 3 no está comprobada.

## Cómo verificar en Windows

Con Rust/MSVC y Windows SDK instalados, desde la raíz del proyecto:

```powershell
.\bench\verify-stage1-modules.ps1
.\bench\verify-stage1-modules.ps1 -FullSuite
```

Si estas pruebas fallan, investigar antes de aceptar esta implementación.
No eliminar validaciones para forzar la aceptación. Las pruebas que revelen
incompatibilidad con Stage 0 deben distinguir entre un defecto y una mejora
necesaria en la semántica formal.

## Ruta final sin otros lenguajes (requisito permanente)

El backend Python→C11 es **transitorio**. El objetivo final se mantiene:
compilador, verificador LIR, generador x86-64/ARM64, emisor ELF/PE,
enlazador y runtime **escritos en ELE**. Las llamadas al sistema operativo
son interfaces de plataforma, no dependencias de un lenguaje fuente externo.
La ruta de producción final no dependerá de Rust, Python, C, GCC ni Clang.
El arranque histórico con un compilador anterior deberá quedar documentado,
pero Stage 2 y Stage 3 deben poder reconstruirse sin ejecutarlo.
