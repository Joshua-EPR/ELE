# Decisiones — 2026-11-07

1. Se leyó íntegramente ESPECIFICACION_L_v1.0.md antes de implementar. Se conserva
   el paquete original en p1. Un crate con módulos evita fragmentación innecesaria.
2. Cranelift fue considerado; no había crates instalados en caché. Se eligió Rust
   como salida intermedia y rustc como backend nativo con el enlazador disponible,
   sin nuevas dependencias. No se afirma haber probado Cranelift ni sus APIs.
3. LIR propio tipado estructurado con IDs resueltos, ramas, bucles, llamadas y spans.
   SSA/bloques básicos quedan pendientes: fase 3 parcial pese a ejecutar nativo.
4. La spec permite inferir retornos; por ahora omitir -> T significa unit. Se exige
   anotación para retornos no unit. Es una limitación temporal del subset, no una
   redefinición del lenguaje. Parámetros y cuerpo de función comparten scope.
5. Última expresión sin punto y coma, incluso con newline antes de }, es tail.
   En cuerpos de control usados como sentencias se descarta; en final de función
   se comprueba contra retorno. No se permite if como inicializador aún.
6. module e import std.io.print se admiten como cabeceras de un solo archivo.
   No hay resolución entre módulos ni visibilidad. Posición/unicidad estrictas
   de cabeceras pendientes; otros imports se rechazan.
7. print es intrínseco de un argumento Int/Float/Bool/Text. En fase 2 Text se consulta
   sin consumirlo, como préstamo compartido temporal propio del intrínseco.
   Efectos explícitos todavía se rechazan, no se afirma pureza ni noalloc.
8. La spec presenta escapes con doble escape textual. Se implementan n/t/r,
   comillas/backslash y u{HEX}. Fase 2 admite Text con ownership conservador.
   Interpolación implementada en el incremento siguiente; {{ y }} producen llaves literales.
9. Fase 2 admite -9223372036854775808 mediante token de magnitud especial solo
   tras menos unario directo. Magnitud positiva aislada o entre paréntesis antes
   del menos aún se rechaza. Bases/sufijos pendientes.
10. Diagnóstico fail-fast L0001; recuperación/múltiples errores pendientes. Límites:
    CLI 256 KiB, parser 4096 tokens, anidamiento 128, semántica expresión 128.
    Las pruebas de entradas malformadas no son una auditoría de seguridad completa.
11. Rust fijado 1.99.1; en este equipo se reutilizó stable-x86_64-pc-windows-msvc
    mediante RUSTUP_TOOLCHAIN después de verificar la misma versión instalada.
12. Segundo incremento: control de flujo CORE-1 con loop/break/continue, else-if
    y bloques léxicos independientes. Sin break con valor ni etiquetas. El
    análisis de retornos no demuestra divergencia de loop todavía: se mantiene
    conservador y se documenta la limitación en vez de aceptar rutas dudosas.
13. Se corrigió el descarte de valores de if/bloques terminados en ;. Se separó
    LIR y sus tipos a lir.rs para que el backend no dependa de parser ni sema.
    Sigue siendo IR estructurado, no bloques básicos/SSA.
14. Fase 2 añade const global/local: solo literales, referencias a const y operadores
    puros del subset. No se ejecutan funciones del usuario durante check. Esto
    limita const, pero garantiza que no haya IO/heap/runtime simulados. Globales
    se resuelven topológicamente; ciclos son error. Const Text materializa un
    valor nuevo por uso de datos estáticos (distinto de mover un binding let/var).
15. Text usa wrapper no Copy sobre UTF-8 estático; movimientos se validan en LIR
    antes de rustc. Se rechaza conservadoramente mover un Text exterior dentro
    de bucles y usarlo tras una rama que pudo moverlo. El análisis aún no elimina
    ramas que retornan ni código inalcanzable: no se anuncia borrow checker completo.
16. Pruebas detectaron que Rust rechazaba overflow literal runtime antes de enlazar.
    Se corrigió con checked_* y helper de panic/abort. Const overflow sí se rechaza
    en compilación. Float se emite por bits para preservar resultados IEEE.
17. Backend Rust sigue provisional; se probó PE autónomo sin fuentes/PATH. No se
    declara backend directo. No hay benchmarks ni afirmaciones de velocidad.
18. No existía Git: se inicializó la rama dev/phase2-const-text. Sin remoto no es
    posible abrir PR. Contrato v1.0 y prompt permanecen sin modificación.
19. Interpolación tiene tokens, AST y LIR propios. Los huecos usan el parser normal;
    no hay reemplazo textual ni casos especiales de print. Scanner comparte cursor
    y posiciones entre texto/expresión; nesting máximo 64 y presupuesto total 4096.
20. La spec no detalla si formatear Text consume el binding: se elige consulta
    compartida temporal, consistente con print. Cada parte se escribe antes de
    evaluar la siguiente; llamadas conservan movimientos normales. Tipos admitidos:
    Text/Int/Bool/Float; unit no tiene representación definida y se rechaza.
21. Text pasa de almacenamiento solo estático a estático o String propietario
    mediante Cow interno, sin Copy/Clone expuestos ni GC. La interpolación dinámica
    puede asignar y abortar por fallo de asignación. No se afirma noalloc.
22. Plegado de interpolaciones solo si son puras, constantes y exitosas; errores
    runtime y llamadas permanecen runtime. Const evaluada exige éxito. Límite de
    1 MiB por resultado constante para contener expansión exponencial. Display
    de Rust para los primitivos ya implementados determina el formato textual.
23. Continuación tras Codex: se verificó la interpolación (Fibonacci: 55, suite verde)
    y se confirmó en Git antes de nuevos cambios.
24. Retorno inferido cuando se omite `-> T` (spec §4: permitido para funciones no
    públicas; no existe pub aún). Sustituye la decisión 4. Punto fijo en vez de orden
    topológico: soporta llamadas adelantadas y detecta ciclos con un error accionable.
25. `for` solo sobre rangos Int en esta fase; la spec define `IntoIterator`, que exige
    genéricos/traits. Instrucción LIR dedicada (ForRange) en lugar de desazucarar a
    while, porque `continue` saltaría el incremento y `..=i64::MAX` desbordaría.
26. `loop` sin break propio cuenta como divergente para el análisis de retornos.
27. Structs no Copy y sin movimientos parciales. Copy opt-in y movimientos parciales
    requieren reglas formales de Fase D; rechazar es seguro y no cierra el diseño.
28. Defaults de campo deben ser constantes (spec §5: "inicialmente expresiones
    constantes sin efectos"); constructores como default se rechazan por ahora.
29. Constructores solo con argumentos con nombre (spec §5). Argumento con nombre en
    llamadas a funciones se rechaza: la spec no define parámetros con nombre.
30. Método estático se invoca `Tipo.m()` (la spec no fija la sintaxis de llamada; es
    coherente con el acceso `.`). Si existe un binding local con ese nombre, gana.
31. En `obj.mutMetodo(args)` los argumentos se evalúan antes de activar el préstamo
    exclusivo del receptor. Permite `c.inc(c.get())`; rechaza mover c en los argumentos.
32. `pub`, traits, genéricos y efectos `!{}` se rechazan explícitamente con
    "feature not implemented" en lugar de aceptarlos e ignorarlos. (pub: ver 39.)
33. Option/Result se definen en un prelude escrito en L como enums genéricos
    ordinarios. El compilador solo sabe que las variantes del prelude se usan sin
    calificar y que `??`/`?` operan sobre Option/Result, como define la spec §7.
34. Genéricos mínimos: solo en enums, por monomorfización (spec §5). Funciones
    genéricas, structs genéricos y traits quedan para su propio hito.
35. Variantes de usuario siempre calificadas (`Estado.Error`), coherente con los
    ejemplos de la spec y con `Tipo.metodo()`. `None` es palabra reservada (spec §1),
    admitida solo como variante.
36. Exhaustividad con el algoritmo de utilidad de Maranget: da también alcanzabilidad
    y ejemplos de casos faltantes con patrones anidados.
37. match como sentencia descarta los valores de los brazos; como expresión exige un
    tipo común entre brazos que terminan. Brazos `return/break/continue` sin llaves
    se admiten como en Rust, ya que la gramática de la spec solo prevé expresiones.
38. Ownership de bindings de match: préstamo por defecto y movimiento solo si el
    binding se mueve (decidido por ownership.rs y registrado en LIR), para que
    examinar un valor no lo consuma. Mover un binding mueve el local entero (sin
    movimientos parciales), y el valor examinado queda congelado en el brazo.
39. `pub` implementado como marca declarativa en un solo módulo; su única regla
    observable hoy es que `pub fn` sin `-> T` devuelve () (spec §4).
40. `T??` en tipos (token `??`) significa `Option<Option<T>>`.
41. Dos niveles de LIR: la estructurada (salida de sema, entrada de ownership y del
    backend rustc) y la de bloques (`cfg.rs`), derivada después de toda la comprobación.
    Rust no tiene goto, así que el backend rustc no puede consumir un grafo sin una
    máquina de estados; reescribirlo no aporta mientras sea provisional.
42. La LIR de bloques usa variables tipadas no SSA; Cranelift construye SSA con
    `def_var`/`use_var`. Más simple de generar y de verificar; correcto por construcción.
43. La aritmética entera de la LIR de bloques tiene semántica de panic en la propia
    instrucción (con span), no ramas explícitas: el verificador y los backends conocen
    el contrato y cada backend elige cómo comprobarlo (Cranelift: `*_overflow` y
    comprobaciones previas a `sdiv`/`srem`, que de otro modo serían excepción de CPU).
44. El lowering a bloques y su verificación corren para todo programa y backend
    (`lib::lower_to_cfg`): los cientos de programas de la suite validan el lowering.
45. Cranelift 0.137.1 (última estable compatible con Rust 1.99.1; 0.138 era release
    candidate), fijado con `=` junto con target-lexicon 0.13.5.
46. Runtime nativo generado como Cranelift IR dentro del propio objeto; solo usa
    kernel32 (`GetStdHandle`, `WriteFile`, `ExitProcess`). Sin CRT: `/NODEFAULTLIB` y
    entrada `l_start`; stack probes en línea para no necesitar `__chkstk`.
47. Contrato de panic común a ambos backends: mensaje definido por L en stderr y
    estado de proceso abortado (0xC0000409 en Windows). El backend rustc pasó de
    `panic!` a `eprintln!` + `abort()` para que la salida no dependa del runtime de Rust.
48. El backend cranelift rechaza en `check` lo que no soporta (L0008) en vez de generar
    ejecutables incorrectos o con fugas; Text dinámico espera a tener asignador y drops.
49. Backend predeterminado: rustc, hasta que cranelift cubra todo el lenguaje y la
    suite diferencial lo demuestre.
50. Primera plataforma nativa: Windows x86-64 (la del entorno de desarrollo) con
    `link.exe` localizado por vswhere y kernel32.lib del Windows SDK.
51. Text nativo = `(ptr, len, cap)`; `cap == 0` = estático. Así un literal y un buffer
    propio tienen la misma forma, mover es copiar tres palabras y el drop de un
    literal es un no-op sin ramas especiales en el código del usuario.
52. Drops explícitos en la LIR, insertados después de sema y ownership: lowering por
    regiones léxicas + elaboración por flujo de datos con drop flags (como MIR de
    Rust) en lugar de decidirlos en el backend. Un verificador independiente
    comprueba el resultado; los backends solo traducen `Drop`.
53. Se rastrean variables completas. Las extracciones parciales marcan el agregado
    como movido (`Moved`); el coste es una fuga documentada en agregados con varias
    partes propietarias, aceptable mientras el backend nativo no los admita.
54. Memoria: heap del proceso de Windows (`HeapAlloc`), sin allocator propio ni GC ni
    conteo de referencias. Un fallo de reserva es panic (nunca un puntero nulo).
55. Funciones que devuelven Text usan un puntero oculto de retorno (sret), propio del
    backend, porque Windows x64 no devuelve tres valores en registros.
56. Instrumentación de memoria opcional (`--trace-alloc`, `--alloc-fail-after`) en el
    propio runtime, en lugar de sanitizers externos no disponibles para este backend:
    contadores, `HeapValidate` por liberación y del heap completo al salir.
57. Pista de capacidad de interpolación = literales + 20 por Int + 5 por Bool (mínimo
    16): eliminó las realocaciones en el benchmark de texto sin cambiar la semántica.
58. Se sustituye la decisión 53 para structs: rutas jerárquicas por campo, estados
    Init/Uninit/Maybe y DropField con flags por hoja. Enums siguen atómicos y no
    se habilitan en nativo mientras no haya drops sensibles a la variante.
59. Layout explícito Windows x64 separado en layout.rs; locales y argumentos de
    structs se descomponen en SSA. Retornos usan sret con padding/alineación reales.
    Es ABI interno, no ABI C ni representación pública estable.
60. Reemplazar un campo evalúa primero el nuevo valor, libera el anterior si aún
    está inicializado y luego almacena. Mover un campo conserva los hermanos.
61. Alcance incremental: ownership por campo y structs nativos primero. Métodos con
    referencias, enums y Option/Result nativos quedan pendientes; rechazarlos es
    preferible a traducir préstamos como copias que no preserven identidad.
62. Soporte nativo de métodos con receptor `self` (`fn` compartido, `mut fn` exclusivo,
    `static fn` sin receptor): Para habilitar mutaciones in-place en Cranelift sin
    copias de estructuras ni pérdida de identidad de objeto, las variables locales
    prestadas a métodos mutables se asignan a `StackSlot` con el tamaño y alineación
    exactos de su layout. Los argumentos `Arg::Ref` reciben un puntero de máquina `I64`
    (`place_addr`). En el cuerpo del método, las variables `VarTy::Ref` se desreferencian
    mediante `load`/`store` directos en memoria con los offsets exactos del layout.
63. Borrow checking conservador y referencias seguras (`&T`, `&mut T`): Validación estática
    de aliasing que garantiza: múltiples lectores o un único escritor exclusivo; prohibición
    de mutar mediante `&T`; prohibición de mover valores mientras estén prestados; prohibición
    de modificar o reasignar mientras existan préstamos de lectura activos; y prohibición
    estricta de devolver referencias a variables locales de stack. Para evitar romper la
    ergonomía y eficiencia del compilador, `lir::Type` se mantiene como `Copy`, modelando
    la condición de referencia en las firmas y parámetros mediante `Option<Receiver>`.
64. Enums nativos y layout etiquetado explícito (EnumLayout, VariantLayout): En Cranelift, cada enum se representa con un discriminante a offset 0 (i64, alineación 8) y el payload de cada variante a partir del offset 8, empaquetado respetando alineación y padding de los tipos de sus campos. El tamaño total del enum se determina por la variante más grande redondeada a la alineación máxima (mínimo 8 bytes). En SSA se representa como size / 8 palabras I64, asociando a cada variable enum un StackSlot dedicado para garantizar dirección de memoria estable al bifurcar y proyectar payloads.
65. Drops condicionados por variante (Variant-Sensitive Drops): Cuando un enum sale de su scope léxico o se descarta, la instrucción Drop emite un switch de Cranelift sobre el discriminante activo, ejecutando únicamente las rutinas de liberación de memoria de los campos dinámicos (Text, structs con Text o enums anidados) de la variante activa, sin tocar memoria inactiva ni incurrir en fugas de memoria o dobles liberaciones. El prelude (Option<T>, Result<T, E>) reutiliza directamente esta infraestructura.
66. Soporte nativo para tipos de coma flotante (Float/f64, f32) bajo IEEE 754: En Cranelift, Float y f64 se representan con types::F64 y f32 con types::F32. Las operaciones (+, -, *, /, unario -) usan instrucciones nativas (fadd, fsub, fmul, fdiv, fneg) sin fast-math. La división flotante por cero no atrapa ni produce pánicos (produce inf, -inf o NaN). Las comparaciones usan fcmp con FloatCC, respetando la semántica de NaN (todas las comparaciones de orden y == son false; != es true) e igualdad de signos de cero (-0.0 == 0.0 es true).
67. Conversiones numéricas explícitas con saturación y formateador nativo l_rt_ftoa independiente de CRT: Conversiones explícitas Float(x), f64(x), f32(x) e Int(x) sin coerción implícita; la conversión a Int utiliza fcvt_to_sint_sat para evitar UB y traps en NaN/overflow. La salida de texto (print e interpolación) utiliza un formateador propio en Cranelift IR (l_rt_ftoa) en runtime sin invocar la CRT de C ni msvcrt.
68. Genéricos, Traits y Monomorfización Nativa Estática: Se implementaron genéricos estáticos y monomorfización para funciones (`fn id<T>(x: T) -> T`), structs (`struct Caja<T>`), métodos (`impl<T> Caja<T>`) y traits (`trait TraitName`, `impl Trait for Type`) con static dispatch y trait bounds (`<T: Trait>`). Para preservar la simplicidad y eficiencia de las representaciones intermedias, `lir::Type` se mantiene `Copy`, `PartialEq`, `Eq`, `Hash`, mapeando cada instancia monomorfizada a índices concretos en `program.structs` y `program.enums`. Cranelift IR opera directamente sobre el código especializado generado sin requerir boxing en runtime ni `dyn Trait`, garantizando cero sobrecoste dinámico e integración transparente con Adaptive Ownership (`heap_ok=1`, `allocs == frees`).
69. Sistema de Efectos Estático, `@noalloc` y Análisis Interprocedimental de Grafo de Llamadas: Se implementó el sistema de efectos estático estricto conforme a la especificación de Proyecto L, soportando anotaciones explícitas de efectos (`!{alloc, io, panic, block}`), pureza estricta (`!{}`) y el atributo de no asignación en heap `@noalloc`. El análisis se ejecuta en una fase dedicada (`crates/l/src/effects.rs`) inmediatamente posterior al typechecking y borrow checking, operando sobre el LIR monomorfizado para analizar cada variante de función/método con tipos concretos. La inferencia de efectos directos analiza de forma conservadora: `alloc` para interpolación dinámica no constante de texto y reservas de heap (`cap > 0`); `panic` para operaciones aritméticas enteras chequeadas (`+`, `-`, `*`, `/`, `%`, `-` unario sobre `Int`), aserciones y pánicos explícitos (las operaciones IEEE 754 de punto flotante no generan `panic` al producir `NaN`/`inf`); `io` y `block` para llamadas al intrínseco `print`. La propagación interprocedimental calcula el punto fijo mediante un algoritmo de lista de trabajo sobre el grafo de llamadas estático. Las trazas de violación se formatean visualmente mediante búsqueda BFS (`f() -> g() -> h()`) con código diagnóstico `L0010 [efectos]`. Los contratos de traits imponen efectos máximos admisibles sobre sus métodos, verificados estáticamente contra las implementaciones monomorfizadas con cero costo en runtime.
70. Contratos de efectos de traits se verifican contra todas las implementaciones
    (antes, solo contra la última declarada: dependía del orden del código).
71. Referencias de segunda clase hasta implementar lifetimes: solo en parámetros y
    como argumentos directos. Se prefirió restringir antes que inferir vidas a medias:
    la implementación previa borraba `&T` a `T` y producía referencias colgantes.
72. Los préstamos pasados a una misma llamada son simultáneos: `&mut` exige
    exclusividad frente a los demás argumentos y al receptor (campos disjuntos sí).
73. Regiones con identidad en el tipo (`Bytes(r)`): el escape se decide por tipos y
    por la imposibilidad de nombrar `Bytes` fuera de `&Bytes` de parámetro, no por
    patrones; la variable de región reutiliza la elaboración de drops ya verificada
    para liberar en todas las rutas.
74. Allocator de regiones: bump sobre bloques encadenados del heap del proceso,
    cabecera en pila (región vacía sin reservas), crecimiento geométrico con mínimo
    4096, memoria a cero. Sin allocator global propio ni GC.
75. Las reservas en región son efecto `alloc` (y `panic`): `@noalloc` no se elude con
    regiones. `alloc(region)` queda como propuesta documentada.
76. Solo `Bytes` en regiones en esta etapa; Text/structs/enums/listas en regiones y
    el pase de análisis de escape se aplazan hasta tener colecciones y lifetimes.
77. Arrays y listas son tipos de movimiento siempre, también `[Int; N]`: no hay copias
    implícitas de colecciones (una copia se escribe como literal nuevo). Se puede
    relajar a Copy para arrays de elementos Copy sin romper programas existentes.
78. Las colecciones son recursos atómicos para el análisis de propiedad: un camino
    que pasa por un índice representa a la colección entera; no se mueve un elemento
    fuera (solo `pop`), y escribir un elemento lo reemplaza (el backend libera el
    anterior). Así no hacen falta drop flags por elemento.
79. Iteración sin consumir: copia de elementos Copy, préstamo de solo lectura de los
    demás; la colección queda prestada todo el bucle (prohibido modificarla o
    moverla). `&mut` por elemento queda para cuando haya lifetimes.
80. Slices como referencias de segunda clase (`(ptr, len)` solo en parámetros) en lugar
    de punteros crudos: un parámetro `&[T]` acepta array, lista o slice del mismo `T`.
81. Política de capacidad única para ambos backends (literal exacto; push
    `max(4, 2·cap)`; reserve `max(len + n, 2·cap)`), observable con `.capacity` y
    verificada por las pruebas diferenciales. Desbordamientos y tamaños negativos son
    panics localizados con el mismo texto en ambos backends.
82. Índices: comprobación dinámica siempre (comparación sin signo), y error de
    compilación para índices constantes demostrablemente fuera de rango en arrays fijos.
83. En nativo, los arrays viven en el marco y se aplanan en componentes (límite 4096);
    las colecciones grandes son `List<T>`. Glue de liberación por tipo de lista como
    función separada para admitir datos recursivos a través del heap.
84. Efectos: array literal sin `alloc`; `List[…]`, `push`, `reserve` = `alloc` + `panic`;
    indexación = `panic` salvo índice constante probado.
85. Colecciones en regiones: **no** en este hito. Requiere que el tipo de la lista lleve
    la identidad de la región (como `Bytes(r)`) y un `push`/`reserve` que crezca dentro
    de la región; sin ello una lista podría sobrevivir a su región. Hito separado.

86. Implementación de la decisión 85. `r.list<T>()` produce una cabecera con
    identidad regional en el tipo. Se admiten movimientos locales y préstamos
    a slices durante llamadas. Los valores regionales no se anidan en agregados.
87. Crecimiento por nuevos rangos de la misma región. Los elementos vivos se
    trasladan, sus drops se conservan y los rangos retirados se contabilizan.
    `push` y `reserve` mantienen `alloc` y `panic`.

88. Extensión local de las decisiones 71 y 80. Se admite `let r = &lugar`,
    `let r = &mut lugar` y anotaciones de slice. El binding conserva su origen
    y el uso lee o escribe por desreferenciación implícita. Los retornos de
    referencias y los agregados con referencias siguen pendientes.
89. Liveness hacia atrás en el CFG. Los représtamos se comparan por el lugar
    original y mantienen sus ancestros vivos. Se distinguen campos disjuntos.
    Los índices se tratan conservadoramente como potencialmente coincidentes.

90. El retorno prestado declara `&T` o `&mut T` y se vincula a un único
    parámetro prestado, incluido `self`. La LIR guarda origen y modo.
    Las firmas ambiguas se reservan para la sintaxis de lifetimes de la
    especificación.
91. El CFG valida la procedencia de todos los retornos, sustituyendo los
    resultados de llamada por sus argumentos de origen. El préstamo retenido
    por el resultado cubre todo ese lugar y conserva la exclusividad del
    argumento original. El ABI nativo devuelve la dirección en un registro.

92. El contrato de retorno se generaliza a un conjunto de parámetros. El
    conjunto contiene todos los préstamos compatibles con el modo del
    resultado. Se aplica como cota superior en llamadas recursivas y no
    depende de seleccionar una rama en tiempo de compilación.
93. Los orígenes locales se resuelven en orden de variable y se deduplican
    por lugar. Se limita cada conjunto a 256 lugares. Se conservan campos
    e índices simbólicos en el informe de escape. El préstamo interprocedimental
    mantiene todo el argumento real para respetar ambos backends.
94. Los slices retornan dirección y longitud. El intento de almacenar
    referencias en un agregado se clasifica con L0014. La política de rechazo
    se mantiene hasta que el tipo del agregado exprese su lifetime.

95. Se permiten structs concretos con campos compartidos de escalares y Text
    como vistas locales. El origen se fija en el constructor y se conserva al
    mover la vista. No se admiten firmas, contenedores, vistas anidadas,
    campos mutables ni reasignación de la vista en este incremento.
96. El CFG reconstruye el préstamo de cada campo por constructor o movimiento.
    Sus usos mantienen vivos los préstamos. El campo guarda un puntero y no
    posee al referente. Los campos propietarios siguen usando drops normales.
97. Retorno de agregados con referencias compartidas vinculadas a parámetros
    formales (`ViewReturn`, `FieldContract`). El llamador recibe la vista mediante
    `by_sret` en Cranelift y preserva la procedencia hasta el parámetro raíz en
    llamadas encadenadas y reenvíos mediante análisis de punto fijo interprocedimental.
98. Préstamos disjuntos por campo en vistas devueltas. Si una vista retiene
    un préstamo a `usuario.nombre`, el compilador permite modificar campos
    independientes como `usuario.edad`, mientras que mutar el campo prestado o
    mover el propietario completo se rechaza estáticamente con L0012. Se adopta
    resolución topológica de alias en `collect_aliases` para evitar dependencias
    cíclicas espurias entre vistas y accesos `FieldLoan`.
99. Referencias mutables en agregados (`&mut T`) y reasignación segura de vistas (`var vista`).
    Se habilita el soporte de campos con referencias mutables exclusivas `&mut T` en structs
    (`Type::MutField(SharedTarget)`). Los agregados con referencias no son `Copy`; cualquier
    transferencia de propiedad mediante asignación invalida el origen (movimiento semántico,
    diagnosticado con L0005 ante reusos posteriores). Los métodos inherentes sobre vistas (`impl VistaMutable`)
    y las asignaciones directas e indirectas por campo (`vista.campo = val`, `self.campo += 1`)
    se desreferencian mediante `FieldLoan` sin sobrescribir el puntero interno.
    La reasignación de variables vistas (`var vista = Vista(...)` seguido de `vista = Vista(...)`)
    se modela en el análisis de flujo de préstamos (`loans.rs`) asignando identificadores de
    préstamo sintéticos por campo para cada variable vista, unificando los orígenes y respetando
    las ramas condicionales sin romper la verificación de LIR SSA. Se rechazan aliasing mutable
    incompatible y préstamos simultáneos con L0012.
100. Referencias en enums, Option, Result, arrays y colecciones (`ViewKey::Payload`, `ViewKey::Index`).
    Se extiende el modelo de préstamos y agregados para soportar tipos compuestos que almacenan
    referencias compartidas y mutables: `Option<&T>`, `Option<&mut T>`, `Result<&T, E>`, `Result<&mut T, E>`,
    enums definidos por el usuario con cargas útiles prestadas, arrays de referencias `[&T; N]`,
    listas dinámicas `List<&T>` y listas regionales `r.list<&T>()`.
    El modelo de préstamos (`loans.rs`) unifica las proyecciones mediante `ViewKey` (`Field(usize)`,
    `Payload(usize, usize)`, `Index(usize)`). En la construcción de variantes (`Rvalue::Variant`),
    únicamente la variante instanciada genera y vincula préstamos para sus campos, evitando
    identificadores sintéticos no inicializados en variantes vacías (p. ej. `Option.None`) que
    producían escapes falsos al retornar. En `collect_aliases`, las referencias reenviadas
    mediante `Rvalue::Use` (como en ramas de `match` o el operador `?`) enlazan directamente
    con el lugar raíz original. Las lecturas de elementos o cargas útiles prestadas se desreferencian
    transparentemente en expresiones de valor, mientras que los contextos que esperan o retornan
    referencias preservan el operando `VarTy::Ref` sin lecturas superfluas.
    Los destructores deterministas conservan invariantes estrictos: las variantes propietarias
    activas (como `Text` en `Result.Err(Text)`) o los búferes de lista se liberan correctamente,
    mientras que los referentes prestados nunca son destruidos ni modificados por el drop.
    Se mantiene paridad diferencial del 100% entre Cranelift nativo y el backend de referencia Rustc.
101. Asincronía con máquina de estados propia en la LIR de bloques, no azúcar
    sobre llamadas síncronas. Cada `async fn` se convierte en tres funciones
    verificadas (constructor, `poll`, destructor del estado) con un despacho por
    punto de reanudación y guardado/restauración de los valores vivos. El backend
    rustc, que es la referencia provisional, reutiliza los futures de Rust: su
    semántica (perezosos, por `poll`, cooperativos) es la misma, y así las
    pruebas diferenciales comparan dos implementaciones independientes.
102. `Future<T>` es un tipo opaco y distinto por función async (como la máquina de
    estados que nombra): no se puede nombrar en una anotación, almacenar en un
    agregado, devolver ni pasar. Evita necesitar borrado de tipos, punteros a
    función y llamadas indirectas en el primer incremento, a costa de que los
    futures se creen y consuman en la misma función.
103. Un bloque del heap por tarea, reservado a cero, propiedad de un único
    manejador. Mantiene direcciones estables mientras la tarea está suspendida
    sin introducir estructuras autorreferenciales móviles. Los futures en pila
    (cuando se demuestre que no escapan) quedan como optimización posterior; no
    se reserva memoria oculta fuera de la contabilidad de `alloc`.
104. El patrón de ceros no posee recursos en ningún tipo de L, así que el
    destructor del estado libera todos sus campos que poseen algo sin consultar
    el punto de reanudación, y mover un valor fuera del estado se acompaña de un
    `Clear` explícito. Alternativa descartada: un análisis de inicialización por
    punto de reanudación con banderas por campo.
105. Nada que posea recursos cruza una suspensión en este incremento: los
    parámetros de una función async son de tipos sin recursos, los locales con
    recursos se liberan antes de suspender y leerlos después es `L0015`, y se
    rechaza suspender con una región abierta o dentro de un `for` sobre una
    colección. Se prefirió rechazar con un diagnóstico claro antes que mantener
    vivo un valor cuya procedencia no se puede demostrar segura.
106. `await` solo como valor completo de `let`/`var`, de una asignación con `=`,
    de un `return` o como sentencia. La suspensión ocurre siempre en un límite de
    sentencia, así que ningún temporal a medio construir tiene que sobrevivirla;
    permitir `await` anidado exigiría guardar temporales arbitrarios en el estado.
107. Crear un future no hereda los efectos de ejecutarlo (solo los de su
    construcción: `alloc` + `panic`); los hereda el `await`. La suspensión
    cooperativa no es `block`. `@noalloc` no puede crear futures: el estado de la
    tarea se contabiliza como reserva en lugar de esconderse en el runtime.
108. Ejecutor cooperativo de una tarea con notificación explícita
    (`Wake`/`TaskWait`): un sondeo solo ocurre tras una notificación y una tarea
    pendiente que no puede ser notificada se informa como interbloqueo, en vez de
    girar en vacío. `TaskWait` es el punto de extensión para `spawn`: ahí se
    ejecutarán otras tareas listas. El contador `suspends` de `--trace-alloc`
    hace observable que la suspensión es real.
109. `spawn f(args)` devuelve un `TaskHandle<T>` opaco y propietario, y el
    planificador pasa a poseer el estado del future que se le entrega. El handle
    apunta a un **registro** de 64 bytes del heap que no se mueve nunca, no al
    estado: separarlos permite destruir el handle mientras el registro sigue en
    la cola de listas. La cola es doblemente enlazada, así que el registro sale
    de ella en O(1) y se libera al cancelar, en lugar de esperar un turno del
    planificador. Alternativa descartada: una tabla de tareas con índices y
    generaciones, que obliga a validar cada acceso y a hacer crecer la tabla.
110. Concurrencia estructurada por construcción: un handle no se puede nombrar,
    almacenar en un agregado, pasar ni devolver, así que no existen tareas
    desatendidas y ninguna tarea puede sobrevivir al scope async que la creó.
    Destruir un handle cancela; terminar el scope destruye los handles vivos. No
    se añadió una operación de cancelación explícita ni una de «desatender»:
    ambas abrirían la puerta a tareas sin dueño antes de poder comprobarlas.
111. Un local cuyo tipo debe sobrevivir a una suspensión vive en un campo del
    estado de la tarea, no en el marco de la llamada a `poll`. Leerlo mueve y
    limpia el campo, de modo que el destructor del campo es correcto sin
    banderas (invariante del patrón de ceros, decisión 104). Es un mecanismo
    general: habilitar otro tipo es añadirlo a `crosses_suspension`, no una
    excepción en el verificador. Hoy solo lo cruza `TaskHandle<T>`, porque para
    `Text`, structs o listas falta demostrar la inicialización por punto de
    reanudación.
112. Planificador de un hilo con cola FIFO (round-robin cooperativo) y
    notificación explícita idempotente: una tarea pendiente no se sondea sin
    notificación, una notificación duplicada o a una tarea terminada o cancelada
    no hace nada, y si no queda ninguna lista con alguna suspendida se informa
    interbloqueo. Sin robo de trabajo, sin prioridades y sin multihilo: primero
    corrección observable (pruebas de traza del intercalado) y después
    rendimiento.
113. El despacho del planificador a la máquina de estados de cada tipo de future
    lo genera el backend (`l_task_poll`/`l_task_drop`) en lugar de guardar
    punteros a función en los registros de tarea. El runtime queda independiente
    de los tipos y todas sus llamadas son directas.
114. La cascada de cancelación es iterativa: una bandera de cancelación en curso
    y una lista de registros pendientes de destruir. La versión recursiva
    desbordaba la pila con árboles de tareas profundos (comprobado con 60 000
    niveles), así que el coste de pila pasa a ser constante.
115. `spawn` hereda los efectos del cuerpo que lanza, además de los de su propia
    reserva. Registrar una tarea compromete su ejecución (solo la cancelación la
    detiene) y no hay un punto léxico donde atribuirlos después, así que se
    atribuyen al `spawn`. Es conservador y mantiene honesto `@noalloc`.


## dev/async-owned-resources

116. Los locales explícitos de tipo `Text` viven en ranuras de enum dentro del
     estado. La etiqueta de variante es el indicador de destrucción. El
     análisis conserva el texto hasta su movimiento o salida de ámbito, y la
     asignación reemplaza su propietario. Las reservas del interpolador y
     los efectos de la tarea conservan sus reglas anteriores.
117. La inicialización de ranuras se verifica sobre aristas lógicas de
     suspensión, ligadas al índice guardado. El despacho efectivo mantiene
     la frontera del marco de sondeo para temporales y préstamos. Extender
     el modelo a agregados requiere representar inicialización y movimientos
     por campo y variante antes de admitirlos en el estado.


## dev/async-owned-aggregates

118. La ranura propietaria se monomorfiza por tipo. Los parámetros por valor
     se transfieren durante la construcción y su inicialización se verifica
     antes de analizar el primer sondeo.
119. Los subárboles de struct se siguen en el CFG por caminos de campos. Se
     dividen donde hay movimientos o escrituras proyectados. Limpiar un
     subárbol movido mantiene la etiqueta exterior y deja una representación
     que no posee recursos. La destrucción reutiliza el layout existente.
120. Un enum persistente o una colección son unidades de propiedad. Al mover
     payloads, un brazo de `match` toma el enum y limpia los payloads que
     extrae, permitiendo el drop de los restantes. Una rama que comprueba
     el discriminante prueba la variante para su payload persistente.
     Las uniones y posibles escrituras invalidan esa prueba cuando
     corresponde. Los préstamos a campos o elementos siguen limitados
     a un sondeo.


## dev/native-async-join

121. `await join(a, b)` es la forma de coordinación binaria. Su resultado
     se infiere como un struct concreto con `first` y `second`. Esta
     representación reutiliza los movimientos y drops de campos.
122. La espera se almacena en el propio padre. La consulta registra el
     mismo padre en ambas hijas. Cada hija puede notificar una vez y la
     cola FIFO deduplica notificaciones encoladas. No se crea una tarea
     intermedia ni una reserva propia de `join`.
123. Los handles permanecen bajo el contrato de concurrencia estructurada.
     La espera binaria permite transferirlos al estado del mismo padre.
     Un futuro `joinAll` requerirá un contrato para colecciones de handles
     que preserve ámbito, propiedad de cada elemento y cancelación.


## dev/native-async-join-all

124. Un grupo de tareas reutiliza una lista propietaria y se confina a
     su cuerpo async. La homogeneidad compara resultados, y el registro
     conserva el tipo real de cada tarea. Los grupos vacíos se infieren
     mediante `taskGroup(funciónAsync)`.
125. La inscripción recorre el grupo una vez. Cada hija pendiente
     conserva un único esperador y la tarea padre conserva un contador.
     La última finalización reencola al padre. La espera y la purga
     mantienen la exclusividad de turno del planificador de un hilo.
126. Los resultados se conservan en los estados de las hijas hasta que
     todo el grupo está listo. La recolección reserva la salida y mueve
     los resultados en orden. Cancelar antes de recogerlos usa los drops
     existentes de los handles y el prefijo inicializado de la lista.


## dev/native-scoped-taskgroups

127. `TaskGroup<T, Scope>` se modela formalmente en el sistema de tipos.
     El scope es una identidad interna asociada a la pila de ámbitos léxicos
     de la función async creadora. El compilador rechaza asignaciones a
     variables de ámbitos más amplios (`outer = inner`), escapes fuera de
     la función, almacenamiento en agregados o colecciones, y cualquier
     intento de préstamo (`&` o `&mut`).
128. La sintaxis canónica `taskGroup<T>()` expone explícitamente el tipo
     de resultado de las tareas. Los métodos `grupo.spawn(f(args))`,
     `grupo.push(spawn ...)`, `grupo.reserve(n)` y `await grupo.joinAll()`
     ofrecen la interfaz completa de concurrencia estructurada, manteniendo
     compatibilidad con `taskGroup(f)` y `await joinAll(grupo)`.
129. En el backend nativo Cranelift, `TaskGroup` comparte la representación
     compacta de 24 bytes `(ptr, len, cap)` de `List`. El destructor nativo
     `task_group_drop_glue` itera los punteros a tareas vivas, invocando
     `l_rt_task_cancel` sobre cada una antes de liberar el búfer con
     `l_rt_free`, evitando recursión en la pila y fugas de memoria.
130. El consumo único se aplica mediante las reglas existentes de Single
     Ownership (Adaptive Ownership). `await grupo.joinAll()` mueve el grupo,
     impidiendo su reutilización o doble espera en tiempo de compilación
     con el diagnóstico `L0005`.


## dev/first-class-futures

131. `Future<T>` se formaliza como abstracción de primera clase en el sistema de tipos
     y en LIR/CFG. Puede almacenarse en variables, moverse conservando single ownership,
     pasarse como parámetro y retornarse desde funciones con firma explícita `-> Future<T>`.
     Retornar un futuro sin anotación de tipo se rechaza con `L0015` para evitar
     la fuga de tipos de máquinas de estado anónimos en interfaces de funciones.
132. Para posibilitar despacho dinámico uniforme sin monomorfización en Cranelift,
     el layout de todas las máquinas de estado sitúa en el offset 0 el campo `tipo: Int`
     (`KIND_FIELD`), en el offset 8 `reanudar: Int` (`RESUME_FIELD`), y en el offset 16
     `resultado: T` (`RESULT_FIELD`). Los parámetros y variables locales comienzan
     siempre en el offset 24+. Gracias a esto, `RESULT_FIELD` mantiene un offset
     estable e invariable para cualquier futuro que produzca `T`.
133. La instrucción LIR/CFG `Rvalue::FuturePoll(place)` y el destructor nativo de
     `Type::Future` leen `kind = *(i64*)state` en tiempo de ejecución y despachan a
     `rt.poll_dispatch` y `rt.drop_dispatch` respectivamente. De igual forma, `TaskSpawn`
     obtiene el `kind` del estado del futuro en lugar de depender de un índice estático
     fijado en la instrucción.
134. Se mantienen las garantías de seguridad de memoria de Adaptive Ownership:
     `Future<T>` no admite préstamos (`&` o `&mut`, diagnóstico `L0012`), no puede
     almacenarse en agregados o colecciones (`L0015`), y cualquier intento de doble
     consumo (doble `await`, doble `spawn` o uso tras movimiento) se rechaza
     estáticamente con `L0005`. Los futuros abandonados o descartados sin sondear
     se destruyen deterministamente liberando todos los recursos propietarios
     capturados con cero fugas de memoria (`allocs == frees`, `heap_ok == 1`).


## dev/general-await-expressions

135. Await como expresión general mediante desazucarado A-Normal Form (ANF) en el
     frontend: cualquier subexpresión compuesta con `await` dentro del cuerpo de una
     función asíncrona se descompone de forma determinista en una secuencia de
     sentencias e instrucciones con temporales sintéticos (`__l_await_tmp_N`). Esto
     preserva el orden estricto de evaluación de izquierda a derecha prescrito por la
     semántica y eleva todos los temporales intermedios a variables locales de primer
     orden dentro del marco léxico de la función.
136. Preservación de temporales propietarios a través de la suspensión: todo operando
     evaluado antes de un punto de suspensión asíncrono se almacena en una variable local
     sintética. El análisis existente de slots de máquina de estados (`collect_slots` y
     `SlotTypes`) asigna automáticamente una ranura en el estado del futuro (`f$estado.lN`)
     con discriminante enum `$async_slot` (Empty/Full). Si el futuro se suspende, los
     recursos propietarios (como `Text`, estructuras o listas) residen en el heap; si se
     cancela la tarea, el drop glue nativo (`f$drop`) los destruye limpiamente con cero
     fugas; si la tarea se reanuda, se leen de su ranura sin re-evaluaciones redundantes.
137. Cortocircuito asíncrono estricto en operadores booleanos: las expresiones lógicas
     `a && b` y `a || b` donde el operando derecho `b` contiene suspensiones asíncronas
     se desazucaran a estructuras condicionales con una variable acumuladora booleana.
     Si el operando izquierdo `a` decide el valor lógico (falso para `&&`, verdadero
     para `||`), el operando derecho `b` jamás se evalúa ni se sondea, garantizando el
     respeto absoluto del cortocircuito sin ejecuciones anticipadas. De forma análoga,
     bucles `while await cond()` se transforman a `loop { if !cond { break } body }`
     para re-evaluar la condición en cada iteración.
138. Confinamiento de ámbito y diagnóstico estricto: `await` permanece estrictamente
     confinado a funciones asíncronas (`async fn`). Cualquier aparición de `await`
     dentro de funciones síncronas o en declaraciones de constantes (`const X = await ...`)
     se rechaza en tiempo de compilación con código `L0015`. Las reglas de Single
     Ownership aplican idénticamente sobre los temporales desazucarados: intentos de
     doble `await` sobre un mismo futuro o uso tras movimiento son rechazados
     estáticamente con `L0005`.

## dev/native-async-timers

139. `sleepMs(Int)` es el builtin inicial. El deadline se calcula
     en el primer sondeo y la duración cero no registra una espera.
140. El heap indexado evita búsquedas lineales en cancelación. La
     purga elimina la entrada antes de destruir el registro de tarea.
141. Windows usa un único objeto de espera para los deadlines. Solo
     se arma cuando la cola FIFO está vacía. La notificación reutiliza
     el wake del scheduler y queda separada de la futura entrada de I/O.


## Fundamentos de self-hosting

142. La primera frontera es un lexer escrito en L que toma `&Text` y
     devuelve tokens propietarios con rangos de byte. `Text.byteLength`
     implementa la propiedad de la especificación. `Text.byteAt(Int)`
     extiende la biblioteca mínima con una lectura comprobada y sin copia,
     que devuelve `Int` mientras falte `Byte`.
143. El bootstrap conserva el frontend Rust, Cranelift y la referencia.
     El backend transitorio propuesto será un proceso con un contrato
     versionado sobre CFG tipado. La importación y la validación de IR
     externa son un hito posterior.


## Driver autónomo

144. El punto de entrada síncrono admite `-> Int` explícito para
     terminar con estado de proceso tras los drops. El rango portable
     es 0–255 y los valores fuera de rango producen 255.
145. Los servicios de argumentos y lectura devuelven valores propietarios
     o estados recuperables. La lectura presta la ruta, limita el
     buffer antes de leer y valida UTF-8 en el mismo almacenamiento.
     El ABI Win64 queda detrás de operaciones tipadas de LIR.
146. El lexer conserva offsets físicos en bytes y el driver calcula
     columnas de escalares. Se admite BOM inicial sin reescribir la
     fuente. La concatenación de fuentes L pertenece al build hasta
     que exista un sistema de imports.

## Paridad léxica, strings, interpolación y sistema de módulos

147. El lexer escrito en L (`compiler-l/src/lexer.l`) alcanza paridad completa con
     Stage 0 para literales de texto, escapes (`\n`, `\t`, `\r`, `\"`, `\\`, `\u{HEX}`),
     validación estricta de escalares Unicode y fragmentación de interpolación
     (`TextStart`, `InterpolationStart`, tokens internos, `InterpolationEnd`, `TextEnd`).
     Los tokens conservan rangos de byte `[start, end)` exactos en la fuente original.
148. La interfaz de cursor de tokens (`compiler-l/src/cursor.l`) provee una abstracción
     reutilizable y sin copia sobre `List<LexToken>` (`cursorNew`, `cursorIsAtEnd`,
     `cursorCurrent`, `cursorAdvance`, `cursorExpect`), preparando la frontera que consumirá
     el parser modular escrito en Proyecto L.
149. El sistema de módulos en Stage 0 (`crates/l/src/modules.rs`) soporta sentencias `import`
     con resolución canónica de rutas (`std::fs::canonicalize`), permitiendo referencias
     locales relativas y submódulos jerárquicos con puntos (`import sub.motor` -> `sub/motor.l`).
     Se elimina la concatenación manual de archivos en `build-lexer.ps1`.
150. La carga de dependencias implementa deduplicación determinista (grafos en diamante)
     y detección estricta de ciclos (`L0014`), consolidando las declaraciones en orden
     topológico previo al análisis semántico y preservando la procedencia de cada diagnóstico.

## Parser autónomo, AST tipado y análisis sintáctico en L

151. Organización modular del AST y límite CORE-1: Para no exceder el presupuesto
     estricto de 4096 tokens por archivo fuente en Stage 0, el parser self-hosted se
     organiza en submódulos especializados (`ast.l`, `parse_util.l`, `types.l`, `expr.l`,
     `stmt.l`, `decl.l`, `parser.l`, `main_parser.l`) enlazados mediante `import`.
152. AST indexado en arenas continuas planas: En lugar de asignar grafos de punteros dispersos,
     se utiliza `AstTree` con listas continuas (`List<T>`) para expresiones, sentencias,
     tipos, declaraciones, parámetros, campos y variantes. La arena `extra: List<Int>`
     almacena secuencias de longitud variable (argumentos, bloques, listas literales, brazos de match).
153. Expresiones Pratt y precedencia homogénea: El analizador de expresiones en `compiler-l/src/expr.l`
     implementa el algoritmo de Pratt con los 9 niveles de precedencia y asociatividad
     idénticos al compilador Stage 0, soportando constructores con argumentos nombrados
     (`Name(k: v)`), métodos encadenados, llamadas genéricas, operadores unarios y binarios.
154. Evaluación ansiosa y funciones de acceso seguro a fin de spans: Como Proyecto L evalúa
     argumentos de funciones de manera ansiosa, `selectInt(cond, ifTrue, ifFalse)` evalúa ambas
     ramas. Para evitar desreferencias fuera de rango con índices `-1` o `pos == 0`, se
     introducen los accesores `astExprEnd`, `astStmtEnd`, `astTypeEnd` y `cursorPrevEnd`,
     garantizando seguridad absoluta ante entradas con errores sintácticos.
155. Sincronización y recuperación con garantía de avance: `parseProgram` y `parseBlock`
     verifican la posición previa del cursor (`before_pos`); si una sentencia o declaración
     falla sin consumir tokens, el cursor avanza al menos un token antes de continuar la
     sincronización (`parserSynchronize`), impidiendo bucles infinitos y asegurando reporte
     limpio de errores múltiples.

## Análisis semántico, resolución de nombres, sistema de tipos y Adaptive Ownership en L

156. Organización modular del analizador semántico y límite CORE-1: Para no exceder el presupuesto
     estricto de 4096 tokens por archivo fuente en Stage 0, el analizador semántico self-hosted se
     divide en submódulos especializados formando un DAG unidireccional estricto: `sema_types.l`
     (tipos y comparadores), `symbols.l` (tabla de símbolos), `scopes.l` (árbol de ámbitos léxicos),
     `ownership_l.l` (máquina de estados de adaptive ownership), `sema_context.l` (contexto y resolución
     de tipos AST), `sema_expr.l` (comprobador de expresiones), `sema_stmt.l` (comprobador de sentencias),
     `sema.l` (orquestador de análisis en dos pasadas) y `main_sema.l` (driver CLI ejecutable).
157. Representación de tipos en arena de índices y equivalencia estructural recursiva: Los tipos
     semánticos se representan como enteros o registros `SemType` dentro de `TypeTable`, asignando IDs
     reservados 0 a 7 a los tipos base (`Unknown`, `Int`, `Float`, `F32`, `Bool`, `Text`, `Unit`, `Error`).
     Los tipos compuestos se internan y deduplican mediante `semTypeMakeRef`, `semTypeMakeList`,
     `semTypeMakeArray` y `semTypeMakeSlice`. La equivalencia `semTypeEquals` opera recursivamente
     admitiendo comodines para evitar cascadas diagnósticas ante errores previos.
158. Resolución de símbolos jerárquica con enlaces padre y sombreado determinista: `ScopeTree`
     mantiene nodos `Scope` vinculados a su padre (`parent: Int`). Cada símbolo registrado en `SymbolTable`
     guarda su `scope_id`. `scopeLookupCurrent` filtra exclusivamente por el ámbito actual para detectar
     colisiones y declaraciones duplicadas (`L0002`). `scopeLookupAll` asciende por la cadena de padres
     buscando la declaración más cercana, lo que resuelve referencias válidas y soporta sombreado léxico
     (*lexical shadowing*) determinista sin requerir listas de símbolos contiguas que puedan desfasarse al anidar bloques.
159. Adaptive Ownership autónomo en Proyecto L: `OwnershipState` rastrea el estado de cada símbolo local
     (`0 = Uninitialized`, `1 = Available`, `2 = Moved`). Al evaluar una expresión por valor de tipo no Copy
     (`semTypeIsMove`), el símbolo se transiciona a `Moved`. Cualquier intento de lectura posterior de un
     identificador en estado `Moved` genera el diagnóstico canónico `error[L0005]: uso de valor movido`.
     En bifurcaciones condicionales (`if-else`), `ownershipMergeBranches` une conservadoramente los estados
     de ambas ramas, marcando el valor como movido si se consumió en cualquiera de ellas.
160. Préstamos inmutables para predicados de enums y tipos no Copy en L: Debido a que todas las
     enumeraciones en Proyecto L son tipos Move (`is_move() = true`), intentar evaluar o pasar un campo
     enumerado de una estructura prestada por valor desencadena `L0005: no se puede mover un campo prestado (self o patrón)`.
     Los predicados formales `semTypeIsNumeric`, `semTypeIsCopy` y `semTypeIsMove` toman préstamos inmutables
     `&SemTypeKind`, y los campos numéricos de símbolos (`type_id`, `decl_id`) se copian a variables locales
     antes de llamar a funciones que toman préstamos mutables de contexto (`&mut ctx`), garantizando total
     estabilidad y conformidad con el borrow checker.


## CFG y ownership de Stage 1

161. Generar eventos de ownership al resolver tipos y símbolos evita
     volver a resolver el AST en un pase paralelo. El CFG de cada
     función tiene aristas por índice y spans para diagnósticos.
162. Un worklist une estados de disponibilidad hasta punto fijo.
     Los campos anidados tienen rutas independientes, y una escritura
     de campo requiere almacenamiento padre disponible.
163. Stage 1 rechaza préstamos con L0012 hasta disponer de liveness,
     procedencia y exclusividad. El CFG retiene predecesores para
     esos análisis y la posterior elaboración de drops.

## Borrow checker de Stage 1

164. Los préstamos se modelan como eventos del CFG de ownership y no
     como un pase separado. La liveness reutiliza los predecesores del
     CFG y el verificador de disponibilidad ignora esos eventos.
165. Un préstamo por sitio sintáctico. La liveness hacia atrás termina
     un préstamo tras su último uso alcanzable (NLL); la exclusividad se
     comprueba contra los préstamos vivos después de cada evento.
166. El contrato de un retorno prestado es la firma, como en Stage 0:
     el resultado retiene todos los argumentos de referencia. Un
     contrato derivado del cuerpo (el `borrow_scan.l` de OpenCode)
     aceptaba programas que Stage 0 rechaza y acoplaba a los llamadores
     con el cuerpo del llamado; se retiró.
167. Los resultados con varios orígenes se representan con nodos
     encadenados por `alt` en lugar de rechazarse. Liveness y
     procedencia siguen `parent` y `alt` en todos los niveles; ambos
     apuntan a ids menores, así que los recorridos terminan.
168. Referencias en structs, colecciones y anidadas se rechazan en
     Stage 1 aunque Stage 0 admita algunas: la invariante de que un
     binding de referencia no sobrevive a su propietario depende de
     ello. Ampliarlo exigirá eventos de fin de almacenamiento.

## Drops de Stage 1

169. Los finales de vida son eventos `FLOW_DROP` del CFG existente,
     emitidos en el bloque de cada arista que abandona un ámbito. El plan
     reutiliza los estados del solver de ownership en lugar de un segundo
     seguimiento de movimientos.
170. Las hojas propietarias se materializan al declarar el binding, en
     orden de declaración, para que el preorden del árbol de rutas dé el
     orden de Stage 0 y los movimientos parciales actúen sobre las
     mismas celdas.
171. La escritura a través de `&mut` es una operación explícita `ref` en
     el plan, también para la raíz, que Stage 0 deja implícita en el
     backend: el plan no depende del backend.
172. El verificador recalcula pares (posee, flag) por hoja sin usar los
     estados del solver, y sus fallos son errores internos (`ICE`), no
     diagnósticos de usuario.
173. La comparación con Stage 0 ejecuta ambos planes por caminos con
     decisiones acotadas y compara la secuencia de lugares liberados,
     identificados por parámetro o por el span de definición que usa el
     lowering de Stage 0.

## Nombre del lenguaje

174. El lenguaje se llama ELE (antes «Proyecto L»); la extensión `.l` se
     mantiene. Cambian los textos visibles para el usuario (documentación
     nueva, ayuda de la CLI y mensajes de runtime, idénticos en ambos
     backends). Paquete, biblioteca, ejecutable, drivers y directorios
     conservan sus nombres para no romper scripts, pruebas ni el historial;
     los documentos anteriores conservan el nombre histórico.

## LIR de Stage 1

175. La LIR de Stage 1 refleja la LIR de bloques de Stage 0 (variables no
     SSA `val`/`ref`, `Assign`/`Store`/`Print`/`Append`/`Drop` y
     terminadores) para que el backend provisional reutilice Cranelift
     sin un ABI nuevo.
176. El lowering se emite durante el recorrido semántico, en el bloque
     CFG actual y anclado al número de eventos. Así se reutiliza el CFG y
     el plan de drops se intercala sin un segundo recorrido del AST.
177. El protocolo es textual y versionado (`ELE-LIR 1`), con textos como
     bytes decimales con longitud: Stage 1 no tiene E/S binaria ni JSON y
     el formato no necesita escapado. Reemplaza la idea de serializar el
     CFG de Stage 0.
178. El backend valida de forma defensiva con los verificadores de Stage 0
     (`cfg::verify`, `drops::verify`) y no ejecuta el frontend Rust.
179. `for` recibe un bloque de incremento propio, destino de `continue`,
     para que el lowering sea correcto.
180. La recuperación de fase 8.2 conserva la extensión provisional de `ELE-LIR 1`, pero no declara listas, enums ni plataforma como capacidades completas hasta probar semántica, ownership, verificador, protocolo y backend. Una ruptura incompatible requerirá una versión nueva.
181. `modules_l.l` se conserva como trabajo heredado, pero su concatenación de fuentes no se acepta como implementación de imports. El hito de self-hosting requiere identidad de módulos, visibilidad, resolución transitiva y diagnósticos por archivo.

182. Fase 8.3 reutiliza la ABI y el runtime de listas de Stage 0, registra `List<T>` parametrizado en `ELE-LIR 1` y añade `FLOW_MUTATE` para mutaciones in situ. La paridad de `flow_cfg.l::flowNew`/`flowBlock` es autocobertura parcial; el protocolo sigue provisional. [Evidencia](PHASE_8_3.md).
