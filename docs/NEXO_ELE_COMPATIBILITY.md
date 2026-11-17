# NEXO v0.4 — Especificación de Compatibilidad y Requisitos de Integración con ELE

**Estado:** Documento normativo de arquitectura para futura integración de NEXO v0.4 en el compilador ELE.  
**Alcance:** Modelado formal de capacidades lineales, representación LIR, invariantes de verificación y requisitos de ABI.  
**Fecha:** 2026-11-16  

> [!WARNING]
> **ESTADO DE INTEGRACIÓN ACTUAL: AISLADO / INVESTIGACIÓN PURA**  
> NEXO v0.4 reside exclusivamente como subsistema desacoplado en Rust dentro de `crates/nexo`.  
> **NO** está conectado a Stage 0, Stage 1, ELE-LIR de producción, sintaxis `.l`, ni al runtime de ELE.  
> Queda estrictamente prohibido declarar implementado Stage 2, Stage 3, self-hosting o soporte nativo de lenguaje mediante banderas ficticias (`--memory-model=nexo`) que redirijan al asignador sin verificación estática completa de punta a punta.

---

## 1. Mapeo de Capacidades Lineales y Tipos de Datos

NEXO v0.4 formaliza una estricta jerarquía tipada que distingue posesión lineal exclusiva, capacidades lineales de reciclaje, marcadores de ámbito estructurado y referencias validadas temporales.

| Tipo Rust en `nexo` | Clasificación de Capacidad | Representación ELE Prevista | Semántica de Posesión y Consumo |
|---|---|---|---|
| `Handle` | Lineal estricta (`!Clone`, `!Copy`) | `dueño<T>` | Dueño único del slot físico. Consumido por valor en `destruir`. |
| `HoleToken` | Lineal estricta (`!Clone`, `!Copy`) | `hueco<P, S>` | Capacidad lineal de reciclaje de hueco. Consumido por `reutilizar_hueco` o `liberar_hueco`. |
| `ScopeMarker` | Lineal estricta (`!Clone`, `!Copy`) | `ambito_marcador<A>` | Testigo de ámbito estructurado en `ScopedArena`. Consumido por valor en `cerrar_ambito`. |
| `CompactPoolToken` | Lineal estricta (`!Clone`, `!Copy`) | `token_pool_compacto<P>` | Autoridad inmutable emitida por registro atómico ($1:1$). Requerida para instanciar adaptadores compactos. |
| `CompactPoolToken16`| Lineal estricta (`!Clone`, `!Copy`) | `token_pool_compacto16<P>` | Autoridad inmutable de 16 bits emitida por registro atómico. |
| `ObjRef` / `CompactObjRef<'a>` | Préstamo no propietario (`'a`) | `&ref<T, 'a>` | Acceso temporal de lectura. Vinculado al préstamo activo del pool. No convertible a `dueño<T>`. |
| `Link` / `CompactLink` | Copiable sin autoridad (`Copy`, `Clone`) | `enlace<P, T>` | Identificador plano de 32 o 64 bits (`slot, gen`). Requiere revalidación dinámica antes de acceso. |

---

## 2. Requisitos de Representación en ELE-LIR (Low-Level Intermediate Representation)

Para que el verificador de ELE pueda razonar sobre programas que utilicen NEXO sin debilitar las garantías del borrow checker, ELE-LIR debe extenderse con los siguientes lugares (*places*) e instrucciones internas:

### 2.1. Instrucciones LIR para `ScopedArena`
- `ArenaNew(capacity: Const<usize>, align: Const<usize>) -> Place::Arena`
- `ScopeBegin(arena: Place::Arena) -> Place::ScopeMarker`
- `ArenaAlloc<T>(arena: Place::Arena, marker: &Place::ScopeMarker, val: Operand::Value<T>) -> Place::LoanMut<T>`
- `ScopeClose(arena: Place::Arena, marker: Place::ScopeMarker) -> Result<(), Place::CloseError>`
  - *Invariante LIR:* `marker` es consumido por valor. Ningún `Place::LoanMut<T>` derivado de este ámbito puede sobrevivir a `ScopeClose`.

### 2.2. Instrucciones LIR para `PhysicalPool`
- `PoolReserve(config: PoolConfig) -> Place::Pool`
- `PoolAllocate(pool: &mut Place::Pool) -> Result<Place::Handle, Place::AllocError>`
- `PoolDestroy(pool: &mut Place::Pool, handle: Place::Handle, keep_hole: Const<bool>) -> Place::DestroyReport`
- `PoolReuseHole(pool: &mut Place::Pool, hole: Place::HoleToken) -> Result<Place::Handle, Place::AllocError>`
- `PoolReleaseHole(pool: &mut Place::Pool, hole: Place::HoleToken) -> Result<(), Place::PoolError>`
- `PoolClose(pool: Place::Pool) -> Result<(), Place::CloseFailure>`

### 2.3. Instrucciones LIR de Revalidación y Acceso
- `Revalidate(pool: &Place::Pool, link: Place::Link) -> Result<Place::ObjRef, Place::RevalidateError>`
- `BatchRevalidate(pool: &Place::Pool, links: Slice<Place::Link>) -> (BitMask, BatchResult)`
- `HoistRevalidate(hoist_ctx: LoopContext, pool_id: Place::PoolId)` (condicionado a ausencia de efectos invalidantes sobre `pool_id` en el cuerpo del bucle).

---

## 3. Verificación de Movimiento, Destructores (*Drops*) y Prevención de Revocación

El análisis de flujo de control (CFG) y el comprobador de préstamos (*Borrow Checker*) de Stage 1 deben imponer formalmente:

1. **Consumo Exhaustivo de Marcadores Lineales:**
   Todo `ScopeMarker` debe ser consumido exactamente una vez en cada ruta del CFG. Si una función retorna anticipadamente o propaga un error, el elaborador de drops (`DropElaboration`) debe emitir la instrucción de cierre o envenenamiento ordenada en LIFO.
2. **Invalidez Inmediata tras Destrucción:**
   La ejecución de `PoolDestroy` sobre un `Handle` invalida en el mismo punto del CFG cualquier préstamo activo derivado de ese slot. El análisis de aliasing debe impedir la coexistencia de `PoolDestroy` con lecturas o escrituras activas sobre `ObjRef` del mismo slot.
3. **Imposibilidad de Conversión de Enlaces a Dueños:**
   Ningún `Link` o `CompactLink` puede promocionarse a `Handle`. El acceso solo puede ocurrir a través de un bloque acotado `revalidate`, cuyo tiempo de vida está subordinado a la existencia del pool y la inmutabilidad de su estado durante el acceso.
4. **Rechazo de Fugas de Huecos:**
   Un `HoleToken` que no sea reutilizado antes de la salida del bloque básico debe ser liberado explícitamente mediante `PoolReleaseHole`. El compilador debe rechazar el descarte implícito sin consumo.

---

## 4. Protocolo de Operaciones del Sistema Operativo y Errores Parciales

El compilador no puede asumir que las llamadas de memoria virtual del SO sean infalibles ni atómicas:

1. **Manejo de `PageState::Quarantined`:**
   Si una llamada del SO a `VirtualAlloc`, `VirtualProtect` o `madvise` retorna un fallo o estado ambiguo, la página física queda marcada irreversiblemente en cuarentena. ELE-LIR debe verificar que cualquier acceso a slots de dicha página falle cerrado inmediatamente con error tipado (`SubpageQuarantined`), sin provocar desreferenciación de punteros nulos o fallos de segmentación no controlados en el proceso anfitrión.
2. **Preservación de Dueño en Fallos de Cierre (`CloseFailure`):**
   Si el SO rechaza la liberación del bloque virtual durante `PoolClose`, la propiedad del pool no se destruye silenciosamente. Se devuelve `CloseFailure<Pool, PoolError>`, permitiendo a ELE registrar el diagnóstico, reintentar o abortar de forma controlada.
3. **Resiliencia ante Pánicos en Destructores:**
   En conformidad con la especificación T6/DROP-01..16 de NEXO v0.4, si un destructor de objeto entra en pánico durante el cierre de un ámbito en `ScopedArena`, la arena debe pasar a `Poisoned`. El offset no debe retroceder para no sobreescribir memoria de objetos vivos, y el bloque virtual sólo puede ser liberado tras el drenaje completo de todos los destructores pendientes.

---

## 5. Requisitos de ABI y Pre-requisitos de Compilador

Antes de evaluar la activación de una bandera experimental en el compilador ELE:

1. **Soporte de Enteros y Alineación Nativa:**
   ELE-LIR debe disponer de tipos primitivos para punteros de tamaño de palabra (`usize`), aritmética de direcciones con detección de desbordamiento (`checked_add`, `checked_mul`), y comprobación estática de alineación en potencia de dos.
2. **Lowering Específico por Plataforma:**
   - Windows: Emisión de llamadas directas a `VirtualAlloc`, `VirtualProtect`, `VirtualFree` con manejo de `GetLastError`.
   - Linux: Emisión de `mmap`, `mprotect`, `madvise`, `munmap` con alineación manual de superpáginas vía sobre-reserva y descarte de prefijo/sufijo.
3. **Eliminación Total de Dependencias del Runtime de Rust:**
   El código generado por ELE para el modelo de memoria debe operar de forma autónoma sin enlazar con `libstd` de Rust, utilizando las primitivas de sistema provistas por la capa nativa de ELE.
4. **Suite de Negativos de Seguridad:**
   Deben compilarse y pasar pruebas que certifiquen que programas erróneos en `.l` (uso tras destrucción, doble liberación de hueco, escape de préstamo de arena, mezcla de tokens de pools distintos) son rechazados estáticamente en tiempo de compilación con mensajes de diagnóstico claros.
