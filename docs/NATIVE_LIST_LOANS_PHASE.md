# Listas nativas y préstamos locales — estado comprobado el 2026-11-11

Incremento heredado: `c8dfc81` en `feat/native-list-cfg`. No se reimplementó.
Stage 1 emite ELE-LIR a partir de `.l`; el verificador y el backend escritos
en ELE producen ELF64. En MSVC, `native_list_l.rs` verificó 5/5 casos:
literales, `push`, `reserve`, `capacity`, `length`, indexación comprobada,
listas de `Text`, `shape` y listas anidadas, campos propietarios, `each`
prestado y préstamos `view`/`edit`. También verificó 24 rechazos y seis
fixtures aceptados que generan imágenes ELF64. Estas comprobaciones Windows
no ejecutan las imágenes Linux; CI sí las ejecutará en Ubuntu.

El encabezado de lista ocupa tres palabras: puntero, longitud y capacidad.
El crecimiento usa `mmap`/`mremap`; la liberación recorre elementos
propietarios y ejecuta `munmap`. El verificador rechaza movimientos o
sobrescrituras de elementos propietarios, préstamos tras crecimiento o
movimiento, préstamos compartidos para escritura y alias mutables. Los
índices se comprueban en ejecución. Estos rechazos son límites actuales,
no soporte de las operaciones respectivas.

Pendiente antes de declarar completo `List of[T]`: `pop` que devuelve
`Option<T>` en el backend ELE; sobrescritura segura de elementos
propietarios; `dropfield` mediante referencias locales; pruebas dinámicas
de los préstamos durante realocación y salidas por todas las ramas.
No hay Stage 2 ni Stage 3 funcionales. El frontend Stage 0 sigue siendo
necesario para construir Stage 1.
