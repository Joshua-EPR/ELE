# Retornos de Agregados Prestados y Lifetimes Interprocedimentales

## 1. Resumen y Objetivos

Este hito extiende el sistema de tipos, el borrow checker de CFG, el análisis de escapes y los backends nativo (Cranelift) y de referencia (Rustc) de Proyecto L para permitir que las funciones retornen estructuras agregadas que contienen referencias compartidas (`&T`), vinculando sus contratos de procedencia y lifetime a los parámetros de entrada de manera estática y sin recolección de basura.

Casos soportados y verificados:
- Retorno de agregados con referencias por valor (`sret` en Cranelift y transpiler).
- Conservación de contratos de procedencia por campo (`FieldContract`) vinculados a parámetros formales (incluyendo `self` en métodos).
- Propagación interprocedimental a través de llamadas encadenadas, reenvíos y llamadas anidadas.
- Préstamos disjuntos por campo: prestar `usuario.nombre` mediante una vista retornada permite modificar campos independientes como `usuario.edad`, mientras que mutar el campo prestado o mover el propietario completo se rechaza estáticamente con `L0012`.
- Agregados mixtos con campos propietarios (p. ej. `Text`) y prestados (`&Text`), garantizando la destrucción condicional de los campos propietarios en el llamador sin liberar nunca el referente prestado (`heap_ok=1`, `allocs == frees`).
- Rechazo estricto de escapes inválidos (`L0014`): referencias a variables locales escalares, campos de agregados locales, temporales de expresiones, elementos de listas locales o buffers regionales.
- Soporte para métodos en structs que retornan vistas (`u.vista()`) y ramificaciones condicionales con múltiples orígenes (`if/else`).

---

## 2. Representación Semántica y Contratos de Retorno

Se definieron las siguientes estructuras en `lir.rs` y `cfg.rs`:

```rust
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldContract {
    pub field_index: usize,
    pub params: Vec<usize>,
    pub projections: Vec<(usize, Vec<EscapeProjection>)>,
    pub mode: Receiver,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewReturn {
    pub params: Vec<usize>,
    pub fields: Vec<FieldContract>,
}
```

- En el chequeo semántico (`sema.rs`), cuando una función retorna un struct que contiene referencias compartidas (`self.is_view(ty)`), se computan los parámetros candidatos y se genera un `ViewReturn` preliminar en la firma `Sig`.
- El tipo vista está permitido como tipo de retorno de funciones y métodos, pero se mantienen las restricciones de seguridad: no se permite anidar vistas dentro de otros agregados, ni usarlas como parámetros por valor, ni instanciarlas con `var`.

---

## 3. Análisis de Préstamos y Punto Fijo Interprocedimental

En `loans.rs`:
- **Construcción y Vistas:** Para las llamadas `Rvalue::Call(callee, args)` cuyo `callee` posee un `view_return`, se mapean los préstamos de cada campo a sus fuentes efectivas a partir de los argumentos y las proyecciones registradas en `FieldContract`.
- **Resolución Topológica de Alias:** Se adaptó la resolución de alias a orden topológico por dependencias con detección de ciclos (`visiting`), eliminando la asunción previa de orden secuencial estricto por `VarId` y resolviendo dependencias de vistas compuestas.
- **Ciclo de Punto Fijo:** En `check(module)` y `escape_summaries(module)`, se itera sobre las funciones hasta converger en la información de procedencia refinada (`view_return`), permitiendo que funciones que reenvían vistas (`reenviarVista(u)`) hereden con precisión las proyecciones del callee original.
- **Liveness Inverso:** En `step`, al retroceder sobre la instrucción `def` que define una vista retornada, se remueven activamente de `live` los préstamos de sus campos, acotando el ámbito del préstamo exactamente al rango entre su definición y su último uso vivo.

---

## 4. Backend Nativo Cranelift y Ejecución Diferencial

- **Cranelift:** Las funciones que retornan agregados vista utilizan el mecanismo estándar de `sret` (puntero oculto en `params[0]`). El llamador reserva el slot de stack y el callee almacena los campos (incluyendo los punteros de 8 bytes de `SharedField`). El acceso posterior mediante `FieldLoan` carga la dirección y la desreferencia limpiamente.
- **Backend Rustc:** Transpila las vistas preservando los lifetimes. Para evitar que el análisis de grano grueso de Rust rechace mutaciones en campos disjuntos legítimos en Proyecto L, la inicialización de referencias almacenadas utiliza coerción de procedencia de solo lectura, confiando en las garantías del verificador de préstamos de Proyecto L ejecutado con anterioridad.
- **Verificación de Memoria:** Se verificó con `--trace-alloc` que ningún byte de memoria escapa ni se libera indebidamente en structs mixtos (`allocs == frees`, `heap_ok=1`).

---

## 5. Pruebas y Resultados de Rendimiento

### Resultados de la Suite
- Total de pruebas unitarias e integración ejecutadas: **195 pruebas exitosas, 0 fallos**.
- `cargo fmt --check`: Limpio.
- `cargo clippy --all-targets -- -D warnings`: Limpio.

### Mediciones de Rendimiento (`loans::profile_aggregate_views`)
- **1 vista, 2 préstamos de campo:**
  - Chequeo completo CFG + préstamos: mediana 501.81 µs (0.50 ms)
  - Solo procedencia y alias: mediana 83.08 µs (0.08 ms)
- **40 vistas, 80 préstamos de campo:**
  - Chequeo completo CFG + préstamos: mediana 10.25 ms (10253.99 µs)
  - Solo procedencia y alias: mediana 2.06 ms (2061.25 µs)

---

## 6. Limitaciones Conocidas y Próximos Pasos

1. **Campos `&mut` en structs:** Reservados para un incremento posterior que garantice exclusividad estricta de aliasing y semántica move pura sin duplicación.
2. **Reasignación de vistas (`var`):** Se mantiene la regla de que las vistas locales requieren bindings `let` con origen estático fijo.
3. **Vistas como parámetros:** Las vistas no se reciben actualmente como parámetros directos por valor en funciones regulares.
