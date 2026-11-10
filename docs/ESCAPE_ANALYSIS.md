# Procedencia y escapes en el CFG

Una función que declara un retorno prestado tiene un contrato
`BorrowReturn { params, mode }`. En un retorno compartido, son candidatos
todos los parámetros prestados. En un retorno mutable, solo los exclusivos.
El receptor implícito ocupa la posición cero cuando existe. El modo también
determina si el resultado permite escritura. El contrato se usa incluso en
llamadas recursivas o mutuamente recursivas. Los cuerpos comprueban la misma
cota superior que consumen los llamadores, así que esta aproximación no
requiere iterar por ciclos del grafo de llamadas.

Los lugares locales distinguen raíz, campos, payloads e índices. Al resolver
una llamada se sustituyen las alternativas del contrato por sus argumentos
reales, conservando las proyecciones de estos. La normalización se resuelve
una vez por variable de referencia. Fusiona alternativas idénticas e
intersecta las autorizaciones de acceso de esas rutas. Se conserva la unión
de ancestros para liveness. Un límite de 256 lugares por referencia evita
expandir indefinidamente conjuntos muy grandes y emite L0013 si se supera.

Cada retorno del CFG debe normalizarse a orígenes incluidos en el contrato.
Una alternativa local, temporal o regional basta para rechazarlo. En el
llamador, las restricciones permanecen hasta el último uso del resultado,
incluidos los représtamos. Una llamada que recibió un préstamo exclusivo
conserva esa exclusividad sobre ese origen aunque retorne una vista
compartida. Los índices dinámicos pueden coincidir. Campos disjuntos de los
argumentos reales mantienen la independencia que ya verificaba el CFG.

`escape_summaries` clasifica parámetros usados solo localmente, reenviados a
una llamada y retornados. Los conjuntos de retorno preservan las proyecciones
que observa el cuerpo, con un índice simbólico para accesos indexados. Las
alternativas deducidas en una llamada siguen siendo una cota superior. El
contrato retiene el lugar completo que recibió el callee. Por ejemplo,
pasar `persona` sigue prestando toda la estructura aunque el método retorne
un campo, mientras que pasar `persona.nombre` conserva ese campo como
lugar de origen. La reducción interprocedimental de esta cota queda pendiente.

Se permiten retornos de slices con tipo compatible. En Cranelift, el
resultado tiene dirección y longitud. La comprobación de límites al indexar
se mantiene. Un slice derivado de una lista regional solo puede sobrevivir
dentro del alcance de la lista y la región del llamador.

El frontend clasifica como L0014 los intentos de guardar referencias fuera de
[vistas locales verificadas](AGGREGATE_LIFETIMES.md), incluidas variantes, Option,
Result, arrays y listas. Copiar un escalar
mediante la desreferenciación implícita conserva un valor, como antes.
No hay destinos desconocidos en los contratos soportados, porque las
llamadas son estáticas y las vistas no cruzan firmas. El informe distingue
`local_view_params` de los parámetros que se retornan o reenvían.

Una posible extensión es `struct Vista<'a> { nombre: &'a Text }`, en línea
con los lifetimes nombrados de la especificación. Requeriría comprobar
la relación entre los argumentos del constructor, el lugar de almacenamiento
y todos los caminos de movimiento, retorno y destrucción. La sintaxis queda
como propuesta.
