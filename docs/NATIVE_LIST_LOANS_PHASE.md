# Listas nativas y préstamos locales — estado comprobado el 2026-11-11

Incremento heredado: `c8dfc81` en `feat/native-list-cfg`. No se reimplementó.
Stage 1 emite ELE-LIR a partir de `.l`; el verificador y el backend escritos
en ELE producen ELF64. En MSVC, `native_list_l.rs` verificó 5/5 casos:
literales, `push`, `reserve`, `capacity`, `length`, indexación comprobada,
listas de `Text`, `shape` y listas anidadas, campos propietarios, `each`
prestado y préstamos `view`/`edit`. También verificó 24 rechazos y siete
fixtures aceptados que generan imágenes ELF64. Estas comprobaciones Windows
no ejecutan las imágenes Linux; CI sí las ejecutará en Ubuntu.

El encabezado de lista ocupa tres palabras: puntero, longitud y capacidad.
El crecimiento usa `mmap`/`mremap`; la liberación recorre elementos
propietarios y ejecuta `munmap`. El verificador rechaza movimientos de
elementos propietarios, préstamos tras crecimiento o
movimiento, préstamos compartidos para escritura y alias mutables. Los
índices se comprueban en ejecución. La sobrescritura de un elemento
propietario libera el valor anterior y transfiere el nuevo. El ejemplo
`native_list_replace_stage1.l` cubre `Text`, `shape` y listas anidadas;
Stage 1 y el backend ELE producen ELF64 en MSVC, y su salida Stage 0 coincide
con el resultado esperado. Falta ejecutar ese ELF64 en Linux CI y comprobar
sus reservas y liberaciones con `strace`.

Pendiente antes de declarar completo `List of[T]`: `pop` que devuelve
`Option<T>` en el backend ELE; `dropfield` mediante referencias locales; pruebas dinámicas
de los préstamos durante realocación y salidas por todas las ramas.
La investigación de `pop` identificó dos bloqueos concretos: Stage 1 todavía
no representa `Option<T>` en ELE-LIR 1, y el backend ELE no analiza ni emite
`i listpop`. Un `match` sobre su resultado producía un ICE de drops; ahora
se rechaza con `L0016` sin emitir LIR. El test de regresión conserva esa
garantía diagnóstica hasta implementar el caso completo.
No hay Stage 2 ni Stage 3 funcionales. El frontend Stage 0 sigue siendo
necesario para construir Stage 1.
