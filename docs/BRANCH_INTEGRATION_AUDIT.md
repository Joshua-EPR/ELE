# Auditoría de integración de ramas — 2026-11-11

Base comprobada: `main` en `46cbe83409918365201950a0b013170cc286109f`.
La rama de listas `feat/native-list-cfg` está en
`c8dfc81e4bf063f09b481f189069178d330a20db`, exactamente un commit
adelante de esa base. GitHub confirmó 22 ramas, incluidas `main` y la rama de
listas. No se fusionó ninguna rama durante esta auditoría.

## Ramas históricas

La comparación de GitHub `main...rama` y la ascendencia local confirman que
estas 12 ramas están detrás de `main` sin commits propios:

- `chore/examples-ele-v2-canonical`
- `feat/ele-original-syntax-v2`
- `feat/ele-runtime-main-integration`
- `feat/native-aggregate-abi`
- `feat/native-refs-text-ops`
- `feat/native-text-fields`
- `feat/native-wide-struct-operands`
- `fix/ele-enum-primitive-pattern-guards`
- `fix/stage0-diagnostics-stacked`
- `fix/stage1-module-cursor-selfhosting`
- `integration/claude-native-text-stage1`
- `integration/ele-native-heap-list-main`

`feat/ele-8.7.4.5-native-interop-ci`, `feat/ele-v2-generic-of-syntax` y
`feat/ele-v2-stage1-of-types` divergen en historia, pero `git cherry` no
encuentra parches exclusivos respecto de `main`; GitHub muestra cero archivos
en la comparación de cada una. No requieren fusión por ahora.

Las cinco ramas siguientes divergen y `git cherry` sí encuentra parches con
identidad distinta. Algunas implementaciones y archivos aparecen también en
`main`, pero eso no prueba equivalencia funcional. Requieren una comparación
de contenido y comportamiento antes de declarar su integración definitiva:

| Rama | Parches exclusivos según `git cherry` | Área |
| --- | ---: | --- |
| `feat/ele-native-heap-mmap-bootstrap` | 9 | heap nativo |
| `feat/ele-native-heap-dynamic-ownership` | 15 | heap y ownership |
| `feat/ele-native-heap-resize` | 23 | realocación |
| `feat/ele-native-int-list-buffer` | 23 | buffer de listas enteras |
| `fix/stage0-diagnostic-files-token-limit` | 2 | diagnósticos y módulos Stage 0 |

Por tanto, la afirmación anterior de que **las otras 20 ramas** están
definitivamente incorporadas o son equivalentes por parche no queda demostrada.

## Protección del estado local

`ELE-baseline` permanece limpio y separado en `46cbe83`. `stash@{0}`
permanece intacto: contiene 514 archivos, mayormente cambios CRLF/LF.
Comparando con su padre e ignorando finales de línea, 13 archivos contienen
cambios sustantivos; los 12 archivos `.l` coinciden con `c8dfc81`. El
archivo Python restante tiene una diferencia posterior en `c8dfc81`.
No se aplicó, descartó ni eliminó el stash. Los únicos archivos sin
seguimiento al inicio eran cachés de Python.
