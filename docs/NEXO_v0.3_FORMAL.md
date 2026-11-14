# NEXO v0.3: especificación operacional y obligaciones de seguridad

Estado: especificación de trabajo para el experimento `ele-nexo`. Este documento
formaliza el subconjunto de NEXO-Core que existe en v0.2 y define la relación que
deberá satisfacer el allocator físico de v0.3. No es una demostración mecanizada.

## 1. Alcance y criterio de evidencia

Esta especificación se deriva de `ir.rs`, el verificador en `verif/`, la máquina
abstracta en `rt/` y las pruebas N01--N28 y P1--P8. NEXO sigue aislado del modelo
de memoria de Stage 0, Stage 1, ELE-LIR y los backends de producción.

Se usan cuatro niveles de evidencia, que no son intercambiables:

- **definido**: aparece como regla en este documento;
- **implementado**: existe una ruta correspondiente en la máquina de v0.2;
- **probado**: una prueba ejecutable cubre instancias de la propiedad;
- **demostrado**: hay una derivación completa y revisable para todos los casos.

Salvo los lemas elementales indicados expresamente, los resultados de este
documento están definidos y, en parte, probados por ejemplos. No están
demostrados ni mecanizados. La implementación Rust tampoco constituye por sí
misma una demostración.

La semántica de abajo es de pasos pequeños. El intérprete actual evalúa bloques
de forma estructurada y más gruesa; demostrar que ese intérprete refina estas
reglas es una obligación separada, O1.

## 2. Dominios y estado estático

Sean dominios disjuntos:

```text
p \in PoolId       s \in SlotId       g \in Gen = {0, ..., 2^32-1}
x \in VarId        f \in FuncId       t \in WorkerId
m \in {view, edit} n \in {Estático, Congelado, Comprobado}
```

`g_ret = 0xffff_fffe` es la generación retirada. Una generación impar menor
que `g_ret` denota un slot vivo; una generación par menor que `g_ret` denota un
slot no vivo. `g_ret` no se incrementa ni se vuelve a asignar.

El entorno estático es:

```text
\Sigma = (Clases, Firmas, Pools_f, Vars_f, Cuerpos, Efectos)
```

`Pools_f` asigna a cada parámetro de pool un permiso `view`, `edit` o `dueño`.
`Vars_f` asigna los tipos que ya existen en `Ty`: enteros, dueños de pila o
pool, préstamos, enlaces, huecos, sellos y referencias de función. `Efectos`
es el menor punto fijo calculado por `verif/efectos.rs`; por pool distingue al
menos crecimiento, destrucción, reestructuración e invalidación de época. Las
reglas R1--R9 y C1--C6 son premisas de formación de `\Sigma`, no se redefinen
ni se debilitan aquí.

Escribimos `\Sigma; \Gamma; \Pi \vdash S ok` para una sentencia bien tipada,
donde `\Gamma` describe variables y capacidades lineales y `\Pi` describe los
permisos de pool de la función o trabajador. La elaboración puede insertar
`Destruir { implicito: true, condicional: ... }`; una marca condicional nunca
crea propiedad, solo evita destruir una variable ya consumida.

## 3. Configuración dinámica

Una configuración es:

```text
C = <\Sigma, P, O, \rho, \Omega, \Lambda, Q, W, K, D, E_x, \tau>
```

- `P : PoolId ⇀ PoolState` contiene los pools existentes.
- `O` contiene objetos de pila y su estado vivo.
- `\rho : (WorkerId, VarId) ⇀ Value` son los marcos y variables.
- `\Omega : ObjectId ⇀ OwnerToken` es estado fantasma de propiedad única.
- `\Lambda` es el multiconjunto fantasma de préstamos activos.
- `Q` contiene colas de destrucción diferida por pool.
- `W` contiene trabajadores, región, partición y estado
  `listo | ejecutando | finalizado`.
- `K` es la continuación: sentencia actual, resto del bloque y marcos de salida.
- `D` son drop flags elaborados.
- `E_x` acumula efectos realmente ejecutados por llamada y pool.
- `\tau` es la traza observable.

`\Omega` y `\Lambda` hacen explícitas las autorizaciones que el verificador
representa mediante flujo de datos. La máquina v0.2 no mantiene ambos mapas
como tablas globales; por tanto, su correspondencia con valores y marcos es una
obligación de refinamiento, no un hecho inspeccionable directamente.

Un pool tiene el estado lógico:

```text
P(p) = <clase, owner, base, cap, gen, estado, datos, libre, hueco,
        e_d, e_r, freeze, particiones, contadores>
```

con:

- `gen[s] : Gen`;
- `estado[s] \in {Vivo, Libre, Hueco, Retirado}`;
- `datos[s]` definido solo si `estado[s] = Vivo` (el almacenamiento de un
  hueco puede seguir confirmado, pero no representa un objeto vivo);
- `libre[s]` y `hueco[s]` como bitmaps lógicos disjuntos;
- `e_d` época de destrucción y `e_r` época de reestructuración;
- `freeze \in Nat`, contador de anidamiento de congelaciones;
- `particiones` como asignadores disjuntos durante `Dividir`.

Los valores relevantes son:

```text
own(o)                         dueño lineal
borrow(o, m, n, e_r)           préstamo
link(p, s, g)                  enlace no propietario de 64 bits
hole(p, s)                     permiso lineal de hueco
seal(p, e_d) | invalid_seal(p) token de sellado
```

Para objetos de pool, `o = (p,s,g)`. El enlace nulo usa la representación cero
y nunca se considera un objeto vivo.

## 4. Buena formación

`WF(C)` exige simultáneamente:

1. todo `own(o)` en `\rho` tiene exactamente el token correspondiente en
   `\Omega`, y no hay otro token para `o`;
2. si `o=(p,s,g)` está vivo, existen `P(p)`, `estado[s]=Vivo`, `gen[s]=g`, `g`
   es impar y `g < g_ret`;
3. `estado[s]=Libre` implica generación par, bit libre presente y ausencia de
   bit de hueco; `estado[s]=Hueco` implica generación par, bit de hueco
   presente y ausencia de bit libre; `Retirado` implica `gen[s]=g_ret` y
   ausencia en ambos bitmaps;
4. todo `hole(p,s)` corresponde a un único estado `Hueco`, y viceversa salvo
   durante el único paso atómico que los consume conjuntamente;
5. cada préstamo de `\Lambda` tiene raíz viva, no ha excedido su región y su
   instantánea `e_r` coincide cuando la operación requiere estabilidad
   estructural;
6. para una raíz dada, o hay préstamos `view`, o hay como máximo un `edit`;
   las excepciones de trabajadores solo alcanzan gránulos/particiones que el
   verificador y el oráculo declaran disjuntos;
7. las particiones de un pool son disjuntas y cada superpágina reservada
   pertenece a un solo asignador;
8. un sello válido solo contiene una época observada después de recorrer todos
   los enlaces almacenados y comprobarlos;
9. el efecto ejecutado acumulado no supera el efecto inferido/asumido de la
   llamada según el orden de efectos de v0.2;
10. `D(x)=vivo` si y solo si la autorización lineal de `x` no ha sido movida,
    destruida ni transferida.

Las comprobaciones de bitmaps, densidad, contadores y pertenencia de
superpáginas de `Pool::comprobar_invariantes` son parte de la representación
concreta de los puntos 2--4 y 7, pero no comprueban por sí solas todo `WF`.

## 5. Juicios y resultados

La transición normal se escribe:

```text
\Sigma \vdash C --a--> C'
```

donde `a` es una observación (`alloc`, `drop`, `read`, `write`, `return`, etc.)
o `\epsilon`. Una operación puede terminar en:

```text
Result ::= Final(v, C) | Abort(kind, C) | PlatformError(code, C)
```

`Abort` es un rechazo controlado antes de un acceso inválido. Se distinguen:

- **recurso**: reserva agotada, generación agotada, profundidad o capacidad;
- **plataforma**: fallo de reserva, commit, protección o release del SO;
- **programa inválido**: permiso inventado, doble liberación, generación
  obsoleta, préstamo invalidado, conflicto de acceso, IR mal formada;
- **defecto interno**: pánico, violación de un `unsafe` o corrupción de
  metadatos. Este último no es un resultado aceptable de la semántica.

Un error de recurso o plataforma debe dejar un estado bien formado y liberar
los recursos parciales de la operación. La atomicidad frente a fallos físicos
es O14; no se presupone demostrada.

## 6. Reglas de transición

Las reglas omiten componentes de `C` que no cambian. `fresh(s,p)` elige según
el algoritmo Bi-Slab un slot libre no retirado del asignador autorizado.

### 6.1 Crear

Premisas: permiso `edit` o `dueño` sobre `p`, `freeze(p)=0`, campos bien
tipados, `fresh(s,p)`, `gen[s]=2k < g_ret` y commit/confirmación exitosa.

```text
gen'[s] = 2k+1       estado'[s] = Vivo      datos'[s] = campos
\rho'[x] = own(p,s,2k+1)                    \Omega' = \Omega + owner(p,s,2k+1)
```

Se quita el bit libre, aumenta el ocupado y se registra `crece(p)`. Si se
almacena un enlace cuya validez no fue probada, también se incrementa `e_d`
como invalidación conservadora. Un fallo de commit no publica `x` ni el token.

### 6.2 Destruir

Premisas: `\rho[x]=own(p,s,g)`, token único presente, `estado[s]=Vivo`,
`gen[s]=g` impar, ningún préstamo incompatible activo y pool no congelado.

Se consume primero lógicamente la autorización. Después:

```text
g+1 = g_ret  => estado'[s]=Retirado
hueco=h      => estado'[s]=Hueco, \rho'[h]=hole(p,s), hueco'[s]=1
en otro caso => estado'[s]=Libre, libre'[s]=1
```

En todos los casos `gen'[s]=g+1`, se elimina `owner(p,s,g)`, se invalida `x`,
se incrementa `e_d` por el efecto de destrucción y se ejecutan drops de campos
propietarios en el orden fijado por la elaboración. Si una subpágina queda sin
vivos ni huecos, puede recuperarse físicamente; sus generaciones no se borran.
Una destrucción diferida encola `(s,g)` y consume el dueño, pero el cambio de
slot y época ocurre al vaciar la cola al salir de la región. En v0.2 no promete
un hueco reutilizable in situ en esta ruta: el marcador producido es inválido y
su consumo cae en una creación ordinaria. Presentarlo como `hole(p,s)` violaría
I5.

### 6.3 Mover

Premisas: `\rho[x]=own(o)`, `\Omega(o)=token(x)` y `y` es un destino válido.

```text
\rho'[x]=consumido     \rho'[y]=own(o)     \Omega'(o)=token(y)
D'(x)=muerto           D'(y)=vivo
```

No se copia ni se recrea el token. Mover un hueco o un pool transfiere del
mismo modo su capacidad lineal. Los valores copiables (`Int`, `view`, enlace,
sello y función) usan `Copiar`, no esta regla.

### 6.4 Prestar para lectura y edición

Para `view`, la raíz debe estar viva y no existir un `edit` incompatible:

```text
\Lambda' = \Lambda + loan(l,o,view,región,e_r(p))
\rho'[l] = borrow(o,view,n,e_r(p))
```

Para `edit`, no puede existir ningún otro préstamo o acceso incompatible sobre
la misma raíz/gránulo. Un représtamo `edit` desde `view` está prohibido. La
salida de región elimina el préstamo; nunca devuelve un dueño consumido. Leer
requiere `view` o superior. Escribir requiere `edit`, `freeze(p)=0` y época de
reestructuración todavía válida.

### 6.5 Enlazar

Premisas: el objeto `own` o prestado identifica `(p,s,g)` vivo. Resultado:

```text
\rho'[x] = link(p,s,g)
```

No se crea token de dueño ni préstamo, y el enlace no prolonga la vida del
objeto. Enlazar un objeto de pila es inválido.

### 6.6 Revalidar

Premisas: `\rho[e]=link(p,s,g)` y permiso de acceso (`view`) o modificación
(`edit`) sobre `p`. En modo `edit` también se exige `freeze(p)=0` y ausencia de
alias incompatible.

La comprobación según nivel es:

```text
valid_Comprobado(p,s,g) = P(p) existe /\ gen[s]=g /\ g impar /\ datos accesibles
valid_Congelado(...)    = lo anterior respaldado por región congelada válida
valid_Estático(...)     = obligación del verificador para el alcance estático
```

Si es falsa se ejecuta exclusivamente `ausente`, sin publicar `ligado`. Si es
verdadera se crea un préstamo delimitado al cuerpo. Al salir se elimina el
ligado y su préstamo. En la variante diferida, la cola se vacía también ante
`Retornar` normal anticipado. La gestión de cola ante un aborto es O7.

### 6.7 RevalidarLote

Se comprueban los enlaces en orden sin publicar ningún ligado. El primer fallo
transfiere a `ausente`. En modo `edit`, dos identidades iguales hacen fallar el
lote. Solo después de validar el lote entero se publican todos los préstamos;
todos se retiran al salir. Esta estructura da atomicidad de exposición, no
atomicidad transaccional sobre escrituras del cuerpo.

### 6.8 ReusarHueco y LiberarHueco

`ReusarHueco` exige el valor lineal `hole(p,s)`, el bit explícito de hueco,
generación par menor que `g_ret`, subpágina accesible y permiso `edit`:

```text
gen'[s]=gen[s]+1       estado'[s]=Vivo       hueco'[s]=0
\rho'[h]=consumido     \rho'[x]=own(p,s,gen'[s])
```

La inicialización de datos precede a la publicación de `x`. No se consulta la
lista libre. `LiberarHueco` consume el mismo valor, cambia `Hueco` a `Libre`,
añade el bit libre y puede recuperar la página. Ninguna regla convierte un slot
libre ordinario en `hole(p,s)`.

### 6.9 Reestructurar

Requiere `edit`, pool no congelado y ausencia de préstamos estructuralmente
incompatibles. Incrementa `e_r` y `e_d`, registra `reestructura(p)` y mantiene
identidades de objeto salvo que una operación concreta especifique su
reemplazo. Todo préstamo con instantánea anterior falla antes de acceder.

### 6.10 Sellar y uso del sello

`Sellar(p)` recorre cada campo de cada slot vivo. Los enlaces almacenados son
relativos al mismo pool (la conversión a `Palabra::Enlace` rechaza otro pool);
para todo enlace no nulo comprueba que su generación coincide en `p`. Si todos
pasan, produce `seal(p,e_d(p))`; si alguno falla, `invalid_seal(p)`.

`SiSellado` toma la rama optimizada solo si el sello no es inválido y su época
es igual a la época actual. Toda operación que pueda destruir o invalidar un
enlace almacenado incrementa la época correspondiente antes de que pueda
observarse el cambio. Si la comprobación falla se ejecuta la rama conservadora.

### 6.11 Congelar y Descongelar

Entrar en `Congelar(p,B)` incrementa `freeze(p)`. Mientras sea positivo se
rechazan crear, destruir, escribir, reestructurar, revalidar `edit` y las demás
mutaciones declaradas incompatibles. Salir de `B`, incluso mediante retorno
estructurado, decrementa exactamente una vez el contador. `Descongelar` es una
transición administrativa de salida, no una sentencia de `Stmt`, y no recupera
permisos consumidos dentro de `B`. Limpieza ante aborto es O7.

### 6.12 TransferirPool

Requiere permiso `dueño`, pool no dividido y ausencia de préstamos escapados.
El token de pool y todos sus dueños vivos pasan al trabajador hijo; el padre no
puede usarlos. Tras finalizar el cuerpo, se ejecutan sus drops y se destruye el
pool. No hay transición de devolución al padre en la IR actual.

### 6.13 Dividir y finalizar trabajador

`Dividir(p,n,...)` requiere `edit`, `freeze(p)=0`, pool aún no dividido y
`1 <= n <= MAX_PARTICIONES_NEXO`. Las superpáginas todavía no reservadas se
reparten en rangos disjuntos y cada trabajador recibe un asignador exclusivo.
Los accesos compartidos restantes deben satisfacer C1--C6 y el oráculo de
gránulos.

Al finalizar un trabajador: (1) se ejecutan sus drops; (2) no quedan préstamos
ni huecos locales escapados; (3) se acumula su época de destrucción; (4) sus
superpáginas y bitmaps vuelven al asignador principal; (5) se realiza el join.
La implementación actual serializa trabajadores en un orden configurable para
explorar intercalados; esto no demuestra corrección bajo memoria débil ni
paralelismo nativo.

### 6.14 Finalizar función y drops implícitos

`Retornar` mueve el valor propietario de retorno, si existe. Después se recorren
las variables elaboradas en el orden determinista del bloque. Para cada drop:

```text
D(x)=vivo   => aplicar Destruir y fijar D(x)=muerto
D(x)=muerto => no-op
```

Los huecos no retornados se liberan; los pools locales se destruyen después de
sus contenidos. Un drop no puede reanimar una autorización. El orden exacto de
elaboración y su equivalencia con todas las salidas de control es O6.

## 7. Invariantes obligatorios

### I1 — Propiedad única

Para todo objeto vivo `o`, `|{ tok | \Omega(o)=tok }| = 1`, y solo una variable
activa representa ese token. En v0.2 lo respaldan el análisis lineal y los
movimientos; falta una demostración por inducción sobre todas las reglas.

### I2 — Consumo lineal

Mover, destruir, reutilizar/liberar un hueco y transferir un pool consumen
exactamente una autorización y ninguna regla la reconstruye desde un valor
copiable. Los drop flags solo consultan consumo previo. Las regresiones de
huecos cubren casos de permiso inventado y doble consumo, no el espacio entero.

### I3 — Generación válida

`link(p,s,g)` identifica al objeto original únicamente si `P(p)` existe,
`gen[s]=g`, `g` es impar y el slot está vivo/accesible. Toda lectura o escritura
procedente de un enlace debe pasar por revalidación o por una prueba estática,
congelada o sellada vigente.

### I4 — Sin ABA

Las generaciones crecen monótonamente sin wraparound. Al alcanzar `g_ret`, el
slot pasa irreversiblemente a `Retirado`; nunca vuelve a listas libres o huecos.
Por tanto, una generación antigua no puede reaparecer en ese slot. Este
argumento es un lema aritmético condicionado a que todas las mutaciones usen
las reglas y a que la representación física preserve `g_ret`.

### I5 — Permisos de hueco

`Libre` y `Hueco` son estados disjuntos aunque ambos tengan generación par.
Solo `Destruir(..., hueco)` produce simultáneamente el bit reservado y el valor
lineal; solo `ReusarHueco` o `LiberarHueco` los consumen simultáneamente.

### I6 — Préstamos

Un préstamo solo puede usarse dentro de su región, con raíz viva, nivel válido
y época estructural compatible. Salir de región, destruir la raíz,
reestructurar o transferir el pool lo invalida según corresponda. El acceso
comprueba la época antes de desreferenciar datos.

### I7 — Exclusividad

No coexiste un `edit` con otro `edit`, `view` o acceso conflictivo al mismo
gránulo, salvo particiones demostrablemente disjuntas. `RevalidarLote edit`
rechaza duplicados antes de publicar ligados. El oráculo dinámico detecta
conflictos entre trabajadores modelados.

### I8 — Sellado

Omitir comprobaciones generacionales requiere `seal(p,e)` válido y
`e=e_d(p)` en el punto de uso. Todo efecto `destruye(p)` o almacenamiento de
enlace no probado invalida la igualdad de época. La completitud de la inferencia
de efectos respecto a todas las llamadas indirectas sigue pendiente.

### I9 — Recuperación

Una página recuperada no contiene un objeto vivo ni un hueco pendiente. Sus
generaciones sobreviven fuera de la página de datos. Antes de leer datos se
comprueban rango, estado de página, identidad y generación; antes de reutilizar
se confirma/protege e inicializa. En el backend físico, esta propiedad exige no
crear referencias Rust que sobrevivan a la desconfirmación.

### I10 — Concurrencia

Para cada par de trabajadores de una región, no hay dos accesos no ordenados al
mismo gránulo donde al menos uno escribe. La disyunción puede provenir de
particiones, ownership transferido o C1--C6. El resultado se limita al modelo
de concurrencia estructurada de NEXO; no afirma ausencia de carreras en hilos
nativos arbitrarios ni bajo un modelo de memoria aún no especificado.

### I11 — Correspondencia abstracto--físico

Si `A R F` y una operación válida hace `A --a--> A'`, el físico debe terminar
con el mismo resultado observable y algún `F'` tal que `F --a/\epsilon*--> F'`
y `A' R F'`; simétricamente, cada operación pública exitosa del físico debe
poder simularse en el abstracto. Errores de plataforma adicionales se permiten
solo si son controlados, no publican estado parcial y preservan `R` con el
estado abstracto anterior. I11 no puede darse por probado hasta existir y
validarse el backend físico diferencial.

## 8. Progreso y preservación

### T1 — Progreso seguro (enunciado condicionado)

Si `\Sigma` está verificada, `WF(C)`, la sentencia actual está bien tipada, los
recursos requeridos están disponibles y las primitivas de plataforma cumplen
su contrato, entonces `C` es final o existe `C'` con `C --> C'`. Sin las dos
últimas hipótesis, se permite un aborto controlado de recurso/plataforma que no
publique capacidades ni referencias parciales.

Estado: **enunciado, no demostrado**. Casos pendientes especialmente delicados:
fallos entre reserva y commit, limpieza al abortar bloques compuestos, llamadas
indirectas, profundidad, destrucciones diferidas y errores internos hoy
protegidos por `expect`.

### T2 — Preservación de tipos y permisos (enunciado)

Si `\Sigma;\Gamma;\Pi \vdash C ok`, `WF(C)` y `C --> C'`, entonces existen
`\Gamma'` y `\Pi'` obtenidos solo por las transferencias/consumos permitidos
tales que `\Sigma;\Gamma';\Pi' \vdash C' ok` y `WF(C')`.

Estado: **lemas parciales** para Const/Copiar/Mover y la aritmética de
generaciones; **pendiente** para el lenguaje completo. Los bloques compuestos
requieren una semántica explícita de continuaciones y una prueba de unión de
estados equivalente a la implementación del verificador.

### L1 — Movimiento preserva propiedad única

Sustituir atómicamente `token(x)` por `token(y)` conserva la cardinalidad uno
de `\Omega(o)`. Este lema es inmediato de la regla de Mover; queda probar que
la implementación realiza la sustitución en todas las rutas de error.

### L2 — Alternancia y no-ABA local

Desde una generación par `g<g_ret`, Crear/Reusar produce `g+1` impar; destruir
produce `g+2` par o retirada. Ninguna regla reduce la generación. Como
`g_ret` se retira, no hay wraparound. Es una prueba aritmética local; depende de
que escrituras de depuración no estén disponibles en ejecución normal.

### L3 — Préstamo válido implica acceso a objeto vivo

Para nivel Comprobado, se sigue directamente de `valid_Comprobado` y de I6.
Para Estático y Congelado falta demostrar que las reglas del verificador y las
restricciones de congelación excluyen cada invalidación durante la región.

### L4 — Sonido del sellado

Si el recorrido es completo, todo enlace almacenado era válido al producir el
sello y toda mutación relevante incrementa `e_d`, entonces la igualdad de época
implica que siguen siendo válidos. Las premisas de completitud del recorrido y
de efectos requieren prueba; por eso el lema no se considera demostrado.

### T3 — Ausencia de carreras en el modelo (enunciado)

Un programa que satisface C1--C6 y preserva I7 no produce accesos conflictivos
no sincronizados en las regiones estructuradas modeladas. Estado: probado por
casos y oráculo para intercalados seleccionados, no demostrado para todos los
programas ni para ejecución paralela física.

### T4 — Destrucción determinista (enunciado)

Fijados programa, entrada y orden de trabajadores, la elaboración y los drop
flags determinan qué autorizaciones se destruyen y en qué puntos de salida.
No implica que direcciones físicas, errores del SO o tiempos sean deterministas.
Falta formalizar el orden total de campos, variables y colas diferidas.

## 9. Relación entre el modelo abstracto y el físico

Sea `A` un estado de `rt::pool::Pool`/máquina abstracta y `F` un pool físico.
La relación `A R F` existe si hay una función de abstracción `\alpha(F)=A` para
los componentes semánticos siguientes:

1. mismo identificador, clase, tamaño lógico de slot, capacidad y base estable
   durante la vida del pool (las direcciones concretas pueden variar entre
   ejecuciones);
2. correspondencia uno a uno de superpáginas lógicas de 64 KiB, cabecera de
   4 KiB y quince subpáginas lógicas de datos;
3. igualdad de `gen[s]`, bit libre, bit de hueco, ocupación, asignador y estado
   vivo/libre/hueco/retirado para cada slot;
4. para cada slot vivo, igualdad de palabras observables; padding y bytes no
   inicializados no son observables;
5. igualdad de `e_d`, `e_r`, congelación, particiones y contadores semánticos;
6. una subpágina abstracta `Confirmada` corresponde a memoria física accesible
   con la protección requerida; `Reservada` o `Devuelta` corresponde a datos
   no accesibles por la API, aunque la reserva virtual siga existiendo;
7. las generaciones y metadatos necesarios sobreviven fuera de páginas de
   datos devueltas y son accesibles sin tocar esas páginas;
8. no existe ninguna referencia Rust viva a una página que pueda protegerse,
   desconfirmarse o liberarse;
9. mappings, commits y protecciones auxiliares pueden dar pasos físicos
   silenciosos siempre que no cambien `\alpha(F)` ni filtren observables.

La dirección base no es un observable abstracto salvo su estabilidad y la
aritmética comprobada dentro del pool. RSS, número de syscalls y política exacta
de reclamación tampoco lo son. Los errores de plataforma sí son observables
controlados y deben dejar la operación sin publicación parcial.

### Obligaciones de simulación por operación

- **Reserva/destrucción de pool**: adquirir/liberar exactamente el rango y
  mantener limpieza aun con fallos intermedios.
- **Crear**: commit y cero/inicialización preceden al estado vivo publicado.
- **Destruir**: invalidar generación precede a hacer recuperable la página.
- **Hueco**: la página permanece utilizable o se reconfirma antes de tocarla;
  el token y bitmap cambian atómicamente a nivel de API.
- **Leer/escribir**: validar rango, estado y generación antes de formar el
  acceso físico.
- **Reclaim/recommit**: nunca leer después de devolver; restaurar protección
  antes de inicializar; conservar generaciones.
- **Particiones**: ninguna superpágina es writable por dos asignadores.
- **Drop**: liberar todos los mappings exactamente una vez.

I11 admite una simulación con tartamudeo (`\epsilon*`) porque commit,
`mprotect`/`VirtualProtect` y reclamación no tienen equivalente visible en el
modelo abstracto. No admite reordenar publicación de identidad antes de que la
memoria sea segura.

### 9.1 Reclamación transaccional (corrección de v0.3)

**Defecto original.** `destroy` y `release_hole` modificaban generación,
bitmaps y contadores y después llamaban a `protect_none`/`decommit`; si el SO
fallaba, la subpágina quedaba `Committed` sin ocupantes (estado que ninguna
transición contemplaba) y el llamador recibía `Err` con la capacidad ya
consumida, induciendo a repetir la destrucción. En Linux, `decommit` hacía
`madvise` antes de `mprotect`, sin estado intermedio registrado.

**Dos capas de estado.** El estado *físico* de cada página (`AddressSpace`)
se registra solo tras la confirmación del SO de cada paso:

| Físico | Backing | Acceso | Transiciones |
|---|---|---|---|
| `Reserved` | no | no | → `Accessible` (commit) |
| `Accessible` | sí | RW | → `Protected` (protect) · → `Discarded` (descarte de un paso, Windows) |
| `Protected` | sí | no | → `Discarded` (descarte) · → `Accessible` (recommit) |
| `Discarded` | no | no | → `Accessible` (recommit, contenido a cero) |

Un rango puede llevar además una marca ortogonal `quarantined`. Esta marca no
afirma un quinto estado del kernel: expresa que la respuesta observada no basta
para confiar en `PageAccess`. Mientras está activa, la vista pública se limita
a `Protected`, toda lectura/escritura falla y `reconcile` normaliza cada página
a un estado conocido e inaccesible antes de retirar la marca.

El estado *lógico* de cada subpágina de datos (`PhysicalPool`):

| Lógico | Confirmada | Acceso físico | Vivos/huecos | Asignable | Reintento | Metadatos conservados |
|---|---|---|---|---|---|---|
| `Reserved` | no | no | no | sí (commit) | — | generaciones iniciales |
| `Committed` | sí | `Accessible` | sí, o ninguno si está en la caché diferida | sí | — | todos |
| `ReclaimPending` | sí | `Accessible` (falló la protección) o `Protected` (falló el descarte) | no | sí (recommit) | sí (`repair`) | todos |
| `Quarantined` | desconocida | no expuesto por la API | no | no | sí (`repair` página por página) | todos |
| `Returned` | no | `Discarded` | no | sí (recommit) | — | generaciones, bitmaps, ocupación |

Transiciones legales: `Reserved → Committed`; `Committed → Returned |
ReclaimPending | Quarantined | Committed(caché)`; `Quarantined →
ReclaimPending | Returned`; `ReclaimPending → Returned | Committed`; `Returned
→ Committed`. `check_invariants` verifica la
combinación lógico×físico de cada subpágina.

**Contratos y arquitectura de dos fases (Fase A / Fase B).**
- *Destrucción lógica*: `destroy(h)` sigue una separación estricta en dos fases:
  1. **Fase A (Prevalidación y preparación)**: Se valida pertenencia de `h`,
     superpágina inicializada (`meta()`), generación viva coincidente,
     decremento exacto `next_live = self.live.checked_sub(1)` (rechaza underflow con
     `PoolError::Invariant`), ausencia de ocupación espuria (`occupied[sub] == 0`),
     incremento exacto de huecos `next_holes = self.holes.checked_add(1)` (rechaza
     overflow con `PoolError::OutOfSpace` si `hole == true`), y consistencia de bitmaps.
     Cualquier error en Fase A devuelve `Err((h, e))` con `h` completamente intacto
     y sin mutación lógica ni física.
  2. **Fase B (Commit lógico irrevocable)**: Aplica de forma infalible la transición:
     invalida la generación lógica del slot (`generation::destroy`), actualiza los
     bitmaps libres/ocupados y sincroniza los contadores de seguridad `live` y `holes`.
     Una vez alcanzada la Fase B, `h` queda consumido y nunca puede ser devuelto al
     llamador.
  3. **Efectos físicos post-commit**: La escritura del espejo físico de cabecera y el
     reclaim físico ocurren tras el commit lógico; si fallan, se reportan mediante
     `DestroyReport` (`HeaderStatus::Stale`, páginas en `ReclaimPending`), garantizando
     que la capacidad lineal permanezca consumida sin inconsistencias.
- *Hueco*: `reuse_hole` y `release_hole` implementan idéntica disciplina de dos fases
  con `HoleToken`:
  - En `reuse_hole`, la Fase A prevalida el token, calcula `holes.checked_sub(1)` y
    `live.checked_add(1)`, y efectúa la puesta a cero física del slot (`space_mut()?.fill(0)`)
    antes de mutar metadatos lógicos. Si falla, retorna `Err((token, e))` con el token intacto.
    La Fase B consume el token, limpia el bit de hueco, publica la nueva generación viva y
    actualiza contadores.
  - En `release_hole`, la Fase A prevalida el token, la desocupación de la subpágina y
    `holes.checked_sub(1)`. La Fase B libera el slot y actualiza contadores.
  Ningún error devuelve una capacidad consumida ni pierde un token intacto.
- *Reclamación física*: un fallo deja la subpágina `ReclaimPending` con el
  estado físico real; ninguna lectura alcanza objetos destruidos porque toda
  validez se decide por generación en los metadatos lógicos, que nunca
  retroceden.
- *Recuperación*: `repair` reintenta reclamaciones y rehace espejos; una
  página pendiente puede reactivarse al asignar (recommit, puesta a cero del
  slot, generación +2); si el recommit falla, nada se publica.
- *Cabecera*: espejo verificado de los metadatos; un fallo de escritura la
  marca sucia sin afectar a la validez.
- *Cierre*: `close` rechaza fugas; si la liberación falla, el pool sigue abierto
  y consistente. `try_close` consume solo tras éxito y devuelve el mismo dueño
  en el error. `Drop` hace tres intentos como último recurso y registra de forma
  agregada un fallo terminal; no puede garantizar liberación persistente.

**Secuencias por plataforma.** Linux: `mprotect(PROT_NONE)` → `madvise(
MADV_DONTNEED)` (la protección previa es obligatoria porque `madvise` no
quita acceso); recommit `mprotect(RW)`. Windows: `VirtualFree(MEM_DECOMMIT)`
en un paso (tras éxito, cualquier acceso falla; tras fallo, nada cambió);
recommit `VirtualAlloc(MEM_COMMIT)`, verificado en ejecución también sobre
páginas protegidas.

**Refinamiento ampliado.** Las observaciones semánticas (identidades,
valores, resultados, rechazos, contadores, agotamiento) coinciden exactamente.
Un `Devuelta` abstracto se corresponde con `Returned`, `ReclaimPending` o
`Committed` vacío en caché; un `Confirmada` abstracto, con `Committed`. Los
fallos inyectados solo afectan al pool físico; una operación que falla antes de
consumir no se aplica al abstracto.

### 9.2 Estado de T1–T4 e I11

| Enunciado | Estado | Evidencia |
|---|---|---|
| T1 progreso seguro | **enunciado, no demostrado** | sin pánicos en las campañas; los `expect` internos de `pool.rs` dependen de invariantes verificados, no de una prueba |
| T2 preservación | **enunciado, no demostrado** | verificador + N01–N28 |
| T3 ausencia de carreras (modelo) | **enunciado, no demostrado** | detector de la máquina abstracta; el pool físico no es `Send`/`Sync` |
| T4 destrucción determinista | **enunciado, no demostrado** | drop flags, S05, `close` |
| I11 correspondencia abstracto–físico | **probado por casos, no demostrado** | arnés diferencial tras cada operación; S12; campañas Windows y Linux |

## 10. Efectos y concurrencia

El orden parcial de efectos se interpreta como una cota, no como una lista de
optimizaciones opcionales. Si `obs(f,p)` es el efecto medido por contadores y
`inf(f,p)` el inferido/asumido, se exige:

```text
obs(f,p) <= inf(f,p)
```

para cada llamada y pool. El punto fijo sobre llamadas directas debe ser
monótono; llamadas indirectas usan el contrato asumido por su tipo. Demostrar
la terminación del punto fijo es sencillo por finitud del retículo, pero la
sonoridad requiere relacionar cada sentencia y cada ruta de error con sus
contadores (O5).

Una región estructurada induce `spawn < acciones del trabajador < join`.
Dentro de la región, trabajadores distintos no están ordenados entre sí. Dos
acciones conflictúan si acceden al mismo `Granulo` (`Dato`, `Gen`, `Meta`,
`Epoca` o `Estructura`) y alguna escribe. La ejecución serial permutada del
oráculo detecta conflictos registrados, pero no sustituye una implementación
atómica ni un modelo de memoria de CPU.

## 11. Matriz de obligaciones pendientes

| Id | Obligación | Evidencia actual | Falta para cerrarla |
|---|---|---|---|
| O1 | El intérprete estructurado refina los pasos pequeños | Tests N01--N28 | Prueba por sentencia y continuaciones |
| O2 | Preservación R1--R9 | Casos positivos/negativos | Inducción completa y formalización de `Gamma` |
| O3 | Preservación C1--C6 | Oráculo y regresiones | Prueba por regiones y gránulos |
| O4 | Linealidad de dueños, pools y huecos | Análisis lineal, disciplina Fase A/B, tests A01–A12 y unitarias | Cubrir joins, retornos, llamadas y errores en compilador |
| O5 | Sonoridad/completitud conservadora de efectos | Punto fijo y P4/P8 | Relación sentencia-contador, indirectas |
| O6 | Drops deterministas y sin fuga en toda salida | Elaboración/drop flags | Orden formal y prueba de todas las salidas |
| O7 | Limpieza de congelación, ligados y diferidos al abortar | Parcial en ejecución normal | Semántica de unwinding/error y pruebas |
| O8 | Validez de niveles Estático/Congelado | Verificador y tests | Lemas de estabilidad por región |
| O9 | Sellado no omite una invalidación | Tests N25 y efectos | Prueba de recorrido y cobertura de efectos |
| O10 | No-ABA global | Retirada y tests de agotamiento | Probar todas las mutaciones físicas |
| O11 | Layout físico cabe y está alineado | Aún dependiente del backend | Aserciones de offsets/tamaños por plataforma |
| O12 | `unsafe` respeta aliasing y validez | No aplica al abstracto | Auditoría de cada bloque físico |
| O13 | Correspondencia I11 | Arnés diferencial tras cada operación (identidad, valores, contadores, refinamiento de páginas), S12, fuzz Windows y Linux | Prueba de simulación |
| O14 | Fallos de SO no dejan estados inconsistentes | Máquina de estados de §9.1, `FaultPlan`, S01–S12, PFS01–PFS12, A01–A12 y fuzz con fallos | Argumento formal por transición; no se provocó un fallo parcial real del kernel (PFS es simulación adversarial) |
| O15 | Reclaim hace datos inaccesibles | Seguimiento físico por página, pruebas de `AddressSpace` (Windows y Linux reales) | Prueba de que ninguna ruta accede a `Protected`/`Discarded` |
| O16 | No quedan mappings al destruir pool | F16, S09, cierre propietario reintentable, reintentos acotados y diagnóstico terminal de `Drop` | Un rechazo persistente del kernel todavía puede filtrar la reserva; `Drop` no puede devolver el error |
| O17 | Progreso sin pánicos internos | Sin pánicos en campañas; tipos testigo `SuperpageIndex` y `Result` en `meta`/`meta_mut` eliminaron todos los `expect` en `pool.rs` | Auditorías en máquina y verificador |
| O18 | Concurrencia nativa | Fuera de v0.2 | Modelo de memoria y primitivas sincronizadas |

## 12. Correspondencia con pruebas existentes

N01--N15 ejercitan propiedad, préstamos, generaciones, enlaces, ciclos y
retirada; N16--N20 revalidación y efectos; N21--N22 transferencia y
congelación; N23--N28 crecimiento durante revalidación, huecos, sellado, lotes,
reclamación lógica, particiones y carreras modeladas. P1--P8 añaden programas
mal formados, secuencias de pool, cierre de efectos y reproducibilidad.

Estas pruebas son evidencia de regresión para instancias concretas. No prueban
I1--I10 universalmente. Ninguna prueba abstracta prueba I11, reserva virtual
real, protección de páginas o ausencia de fugas de mappings.

## 13. Limitaciones explícitas

- No hay prueba asistida por Coq, Lean, Isabelle, K, Creusot ni herramienta
  equivalente.
- El estado fantasma de propiedad/préstamos no es una tabla runtime completa.
- La semántica de excepciones/abortos dentro de bloques compuestos aún no está
  cerrada; retorno normal sí tiene rutas específicas en la máquina actual.
- La concurrencia actual explora órdenes seriales y conflictos lógicos, no
  ejecuta trabajadores nativos simultáneos.
- La recuperación de v0.2 elimina un `Vec` y cambia un estado lógico; no prueba
  semántica de `mmap`, `mprotect`, `madvise`, `VirtualAlloc` o `VirtualFree`.
- Los detalles físicos, el layout binario y las rutas `unsafe` se validan por
  plataforma: Windows x86-64 de forma nativa y Linux x86-64 ejecutando en WSL2
  (kernel 5.10), tanto con binarios `x86_64-unknown-linux-musl` como con el
  toolchain Linux/glibc de Ubuntu. Un kernel Linux fuera de WSL2 no se ha
  probado.
- Esta formalización no integra NEXO en ELE, no cambia ABI, LIR, ownership ni
  sintaxis pública y no implica Stage 2 ni self-hosting.

El criterio para elevar una propiedad de “definida/probada por casos” a
“demostrada” será cerrar sus obligaciones con una derivación revisable. El
criterio para I11 será, además, ejecutar comparación diferencial tras cada
operación y justificar formalmente cualquier diferencia física no observable.
