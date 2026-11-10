# Arquitectura de bootstrap de ELE

## Fronteras entre componentes

Stage 0 sigue siendo el compilador Rust existente. En la ruta nativa
`lexer → parser → sema → LIR estructurada → CFG + drops + verificación → Cranelift → PE`.
La referencia consume LIR estructurada y emite Rust, tras verificar también el
CFG. Ambas rutas se conservan para pruebas diferenciales.

El primer componente en L está en `compiler-l/src/lexer.l`. El script
`compiler-l/build-lexer.ps1` lo combina con el emisor y el driver porque
los programas L todavía se compilan como una unidad de fuente. El
ejecutable resultante abre sus entradas en ejecución. Cuando existan
módulos se separarán mediante imports el driver, el
frontend, las fases semánticas, las IR y los servicios de plataforma según sus
interfaces. Cada directorio aparecerá al incorporar su primera implementación.

| Frontera | Contrato y ownership |
| --- | --- |
| Driver → plataforma | Implementado para argumentos Unicode, lectura UTF-8 acotada, diagnóstico por stderr y estado de salida. La API devuelve valores propietarios o errores y la capa Win64 controla los handles. [Driver autónomo](LEXER_FILE_CLI.md). |
| Lexer → parser | `lexSource(&Text) -> Result<List<LexToken>, LexError>`. Rangos de byte semiabiertos e IDs de clase. El caller conserva la fuente. Los tokens poseen sus metadatos y carecen de referencias internas. |
| Parser → sema | Propuesto. Arena de nodos indexada, rangos y IDs de símbolos. El diagnóstico guarda el identificador de fuente y rango, y el driver calcula línea y columna al presentar. |
| Sema → IR | Propuesto. Tablas de tipos concretos, funciones e instrucciones con IDs. Movimientos y préstamos se validan antes de elaborar el CFG. Las operaciones de memoria y drops deben conservar su información hasta la verificación. |
| IR → backend | Propuesto. Protocolo versionado para CFG tipado, target y opciones, con salida objeto o ejecutable y diagnóstico estructurado. El productor conserva sus buffers hasta enviarlos. |

## Backend transitorio

La primera integración de extremo a extremo usará un proceso backend que
recibe CFG serializado y reutiliza el verificador, Cranelift y el enlazador de
Stage 0. No hay formato ni comando de importación todavía. Se empezará con
un subconjunto de instrucciones y un contrato explícito para layout, tipos,
spans, terminadores y destinos. Un encabezado con versión y target permite
rechazar entradas incompatibles. La importación debe limitar tamaños y
profundidad y validar índices, contratos de ownership y ABI antes del codegen.
El verificador actual consume IR interna. Antes de exponer el protocolo hay que
auditar sus precondiciones y agregar pruebas de IR malformada.
Para invocarlo desde L harán falta escritura binaria y una API síncrona
de procesos con argumentos separados y captura del estado de salida.
La primera versión del transporte puede usar archivos temporales. La
elección de formato y transporte se comprobará con entradas truncadas,
versiones desconocidas y fallos del proceso hijo.

| Estrategia | Coste y uso |
| --- | --- |
| Proceso externo y CFG versionado | Elegida inicialmente. Aísla fallos y no requiere FFI de L. Tiene coste de arranque, lectura y codificación, que deberá medirse con compilaciones completas. Comparte los límites de target y SDK de Stage 0. |
| Puente ABI estable | Posible después de FFI. Un wrapper propio debería exponer versiones, buffers con longitud, códigos de error y funciones de liberación simétricas. Obliga a estabilizar la frontera y probar compatibilidad binaria. |
| Biblioteca nativa intermedia | Puede reutilizar el mismo protocolo en memoria y eliminar coste de proceso. Añade distribución por target, manejo de fallos en proceso y contratos de allocator. |
| CLI de Stage 0 sobre fuente | Ya disponible para bootstrap y referencia. No sirve como prueba de self-hosting, porque vuelve a ejecutar el frontend Rust sobre la fuente. |
| Backend propio | A largo plazo. Implica selección de instrucciones, registros, ABI, objetos y nuevas pruebas de ejecución. Requiere primero una especificación de IR y una referencia con equivalencia demostrada. |

## Etapas y comprobación

0. **Stage 0.** Compilador actual, pruebas del repositorio y backends de
   referencia. El incremento de lectura de bytes y lexer inicial se construye
   con esta etapa.
1. **Stage 1.** Stage 0 compila un driver L con frontend y emisor de IR de un
   subconjunto declarado. El driver invoca el backend transitorio. El
   subconjunto se amplía hasta admitir el código del propio compilador.
2. **Stage 2.** El ejecutable de Stage 1 procesa los fuentes del compilador en
   L y produce el siguiente ejecutable. La prueba comprueba que la ruta del
   frontend Rust no intervino.
3. **Stage 3.** Stage 2 vuelve a compilar el mismo código con el mismo target,
   configuración y backend versionado.
4. **Stage 4.** Comparar los diagnósticos normalizados, los programas aceptados
   y rechazados, la salida, el estado de terminación y, donde corresponda, la
   semántica del IR y la reproducibilidad de artefactos. La igualdad binaria
   solo será exigible tras controlar metadatos y enlazador.

Self-hosting se comprueba en Stage 2 y se valida con el ciclo posterior. La
independencia completa exige sustituir las partes críticas en Rust que sigan
en la ruta habitual, incluido el backend transitorio. Ya se puede ejecutar el
binario que genera Cranelift sin instalar el toolchain Rust.

## Estado tras la fase 7

```text
fuente .l -> Stage 1 (lexer, parser, sema, ownership, préstamos, drops,
             lowering, verificador de LIR; escrito en ELE)
          -> ELE-LIR 1 (texto)
          -> backend provisional (Rust: protocolo, validación, Cranelift,
             enlazado)
          -> ejecutable nativo
```

La frontera es el [protocolo LIR](LIR_PROTOCOL.md). El backend no ejecuta
el frontend Rust; solo valida la LIR recibida de forma defensiva.

## Estado comprobado en fase 8.2

El pipeline anterior funciona para el subconjunto de integración probado. La auditoría actual confirma nueve fuentes propias aceptadas por Stage 1 en modo ownership, pero ninguna de las probadas llega a LIR completa. `modules_l.l` aún concatena fuentes y no constituye resolución semántica de imports. Stage 2 y Stage 3 no existen; Cranelift, protocolo, validación defensiva y enlazado siguen dependiendo de Rust. Ver [matriz de autocobertura](STAGE1_SELF_COVERAGE.md).
