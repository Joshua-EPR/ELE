# NEXO v0.4: Metodología y Escenarios de Benchmarking

**Estado:** Documento de diseño y análisis de rendimiento para NEXO v0.4.  
**Rama:** `feat/nexo-v0.4-next-memory`  
**Fecha:** 2026-11-15  

---

## 1. Escenarios de prueba comparativos

Para contrastar el allocator físico estándar de NEXO v0.3 frente a las optimizaciones de NEXO v0.4 (`ScopedArena`, generaciones compactas y revalidación optimizada), se definen 10 escenarios estandarizados:

1. **Escenario 1 (Asignaciones temporales en ráfaga)**:
   - Asignación y destrucción de 100.000 objetos pequeños (64 bytes) dentro de un único ámbito.
   - *Comparativa*: `PhysicalPool` vs `ScopedArena`.
2. **Escenario 2 (Grafos enlazables densos)**:
   - Inserción de 50.000 nodos interconectados mediante enlaces.
   - *Comparativa*: Enlaces estándar (8 bytes) vs Enlaces compactos (4 bytes).
3. **Escenario 3 (Ciclos aleatorios de inserción/borrado)**:
   - 200.000 operaciones mixtas (50% asignación, 30% destrucción ordinaria, 20% huecos).
4. **Escenario 4 (Reutilización intensiva de huecos)**:
   - Creación de 10.000 huecos lineales y reutilización completa mediante `reuse_hole`.
5. **Escenario 5 (Pools dispersos y compactación)**:
   - Asignación de 50.000 slots y liberación del 90% para medir fragmentación y comportamiento del `DensityIndex`.
6. **Escenario 6 (Reclamación y descommit de páginas físicas)**:
   - Medición de la sobrecarga de `on_empty` y descarte físico al vaciar superpáginas.
7. **Escenario 7 (Revalidación en bucle caliente)**:
   - 1.000.000 de lecturas por enlace dentro de un bucle sin efectos invalidantes.
   - *Comparativa*: `revalidate` dinámico repetido vs *Hoisting* fuera del bucle.
8. **Escenario 8 (Revalidación agrupada en lote)**:
   - Validación simultánea de 64 enlaces en una sola llamada de inspección de metadatos.
9. **Escenario 9 (Fase congelada)**:
   - 500.000 lecturas concurrentes sobre un pool en estado congelado (`Freeze`).
10. **Escenario 10 (Destrucción masiva por ámbito)**:
    - Limpieza en lote de 20.000 objetos al salir de un ámbito versus 20.000 destrucciones individuales.

---

## 2. Métricas y metodología de medición

- **Tiempo de CPU**: Nanosegundos por operación (ns/op), mediana, percentiles p95 y p99.
- **Memoria física**: Working Set (Windows) / RSS (Linux), memoria virtual comprometida (*Committed bytes*).
- **Sobrecarga de metadatos**: Bytes de metadatos por byte útil de carga útil.
- **Llamadas al sistema operativo**: Conteo total de llamadas `VirtualAlloc`/`VirtualFree` (Windows) y `mprotect`/`madvise` (Linux) registrado mediante `OsCalls`.
- **Reproducibilidad**: Mínimo 5 ejecuciones independientes con cálculo de coeficiente de variación (CV < 5%).

---

## 3. Resultados empíricos de ejecución (`nexo-physical-bench`)

Mediciones obtenidas en perfil `release` (optimizado) sobre arquitectura x86_64:

```text
nexo-physical-bench os=windows arch=x86_64 warmup=2000 iterations=20000
physical hot allocate+free:    total_ns=7443100   ns_per_op=372.15
physical hole destroy+reuse:   total_ns=6465100   ns_per_op=323.25
physical commit+reclaim:       total_ns=66924100  ns_per_op=3346.20
abstract allocate+free:        total_ns=1476800   ns_per_op=73.84
Rust global Box<[u8;64]>:      total_ns=2266000   ns_per_op=113.30
memory reserved=524288 committed=8192 useful=64 external_metadata_lower_bound=584 header_used=4095
```

### Tabla comparativa de latencia por operación

| Operación / Asignador | Latencia media (ns/op) | Sobrecarga de Sistema Operativo | Notas de diseño |
|---|---:|---|---|
| **Abstract allocate + free** | **73.84 ns** | Nula (memoria de proceso en espacio de usuario) | Modelo lógico de referencia en memoria pura. |
| **Rust Global `Box<[u8; 64]>`** | **113.30 ns** | Nula (gestor heap del runtime) | Asignador global estándar de Rust sin garantías físicas. |
| **Physical hole destroy + reuse** | **323.25 ns** | Nula en camino caliente (reutilización de `HoleToken`) | Reciclaje lineal de huecos con comprobación de generación. |
| **Physical hot allocate + free** | **372.15 ns** | Mínima (páginas ya confirmadas en superpágina) | Asignación con avance generacional e indexación de densidad. |
| **Physical commit + reclaim** | **3.346.20 ns** | Alta (`VirtualAlloc` + `VirtualFree` / `mprotect` + `madvise`) | Ciclo completo de confirmación física y descarte al sistema operativo. |

### Análisis de resultados

1. **Eficiencia de reciclaje de huecos (`HoleToken`)**:
   La reutilización de huecos mediante `reuse_hole` (323.25 ns/op) es un 13% más rápida que la asignación fría `allocate + free` (372.15 ns/op), confirmando la ventaja del reciclaje guiado por capacidades lineales sobre el barrido de bitmaps libres.
2. **Impacto de las llamadas de memoria virtual del kernel**:
   El ciclo de `commit + reclaim` (3.346.20 ns/op) está dominado por las transiciones de modo núcleo del sistema operativo. Por este motivo, el diseño de NEXO utiliza amortización por superpáginas de 64 KiB y política de descommit diferido (`ReclaimPolicy::Deferred`), evitando llamadas al kernel en el camino caliente de ejecución.
3. **Validación de fuzzer físico bajo inyección de fallos**:
   La campaña `nexo-physical-fuzz --fallos 1000 16` ejecutó 16.000 comandos de asignación, reparación e inyecciones del SO en 16 campañas independientes con **0 divergencias** observadas entre el modelo de referencia y el allocator físico real.
