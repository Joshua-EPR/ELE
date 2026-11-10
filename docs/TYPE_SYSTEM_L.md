# Sistema de tipos de Stage 1

`compiler-l/src/sema_types.l` guarda tipos en una arena `TypeTable`.
Un `Int` identifica una entrada. Cada `SemType` contiene su clase,
el rango del nombre, un ID de tipo de elemento y un ID de declaración
nominal. La tabla es independiente del layout de máquina.

| ID | Tipo | Propiedad en el análisis |
| ---: | --- | --- |
| 0 | Unknown | Marcador de inferencia incompleta |
| 1 | Int | Copy |
| 2 | Float | Copy |
| 3 | F32 | Copy |
| 4 | Bool | Copy |
| 5 | Text | Move |
| 6 | Unit | Copy |
| 7 | Error | Marcador para evitar errores en cascada |

`semTypeEquals` compara IDs y tipos primitivos. Para structs y enums
compara el ID de la declaración. Para referencias y contenedores que
tienen tipo de elemento comprueba la clase y el tipo interno. Unknown
y Error admiten recuperación. La igualdad de arrays aún no distingue
longitudes. Las entradas para referencias, listas, arrays y slices se
pueden reutilizar mediante búsqueda lineal. El driver rechaza referencias
y slices de fuente hasta poder verificar aliasing. Los tags Option y
Result no implican soporte de payloads o propagación en el pase de CFG.

El pase semántico comprueba tipos al recorrer el AST y genera eventos
sobre rutas. Un campo usa el tipo de su declaración para decidir si
la transferencia consume su lugar. Los constructores del subconjunto
exigen campos explícitos. El CFG conserva IDs de símbolos y campos
sin duplicar los tipos. Stage 0 mantiene su modelo original en
`crates/l/src/lir.rs`, `sema.rs`, `ownership.rs` y `loans.rs`.
[Cobertura y verificación diferencial](STAGE1_CFG.md).
