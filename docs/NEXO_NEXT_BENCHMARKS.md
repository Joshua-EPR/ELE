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

---

## 4. Resultados ampliados multicorrida (`--completo`) y análisis de memoria

Para evaluar la estabilidad estadística y la repetibilidad de las mediciones, se ejecutó el arnés en modo ampliado con 7 corridas independientes sobre lotes de 200 operaciones por escenario (`nexo-physical-bench --completo`), con acumulación agregada de contadores a través de todas las corridas (`RUNS = 7`, `ITERATIONS = 20.000`, denominadores exactos por operación):

### 4.1 Métricas de latencia y llamadas al sistema (7 corridas × 200 ops por lote)

Entorno de medición: `os=windows`, `arch=x86_64`, `warmup=2000`, `iterations=20000`, `profile=release`.

| Escenario | Media (ns/op) | Mediana (ns/op) | p95 (ns/op) | p99 (ns/op) | CV% | Alloc/op | SO/op | Cab B/op | Huecos/op |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Revalidar estándar puro (`PhysicalPool`)** | **14.5** | 13.5 | 20.5 | 26.0 | 7.1% | 0.004 | 0.000 | 0.0 | 0.000 |
| **Revalidar compacto 32b (`CompactPhysicalPool`)** | **22.7** | 22.0 | 23.0 | 43.0 | 1.0% | 0.004 | 0.000 | 0.0 | 0.000 |
| **Revalidar compacto 64b (`CompactPhysicalPool64`)**| **23.0** | 22.5 | 23.0 | 42.0 | 0.7% | 0.004 | 0.000 | 0.0 | 0.000 |
| **Revalidar estándar + leer (`PhysicalPool`)** | **53.1** | 51.5 | 63.0 | 90.0 | 3.9% | 0.004 | 0.000 | 0.0 | 0.000 |
| **Ráfaga 960 alloc + 960 free (por op)** | **180.9** | 184.0 | 219.5 | 256.0 | 1.8% | 0.008 | 0.016 | 21.4 | 0.000 |
| **Pool pequeño (1 superpágina)** | **310.6** | 308.0 | 312.0 | 394.0 | 1.0% | 0.004 | 0.000 | 42.0 | 0.000 |
| **Larga duración: 900 vivos + churn** | **312.4** | 309.5 | 317.5 | 358.5 | 1.1% | 0.004 | 0.000 | 42.0 | 0.000 |
| **Fragmentado: 450 subpáginas a medias** | **318.0** | 312.0 | 314.0 | 540.0 | 4.9% | 0.005 | 0.000 | 42.0 | 0.000 |
| **Commit + reclaim diferido (`keep=1`)** | **321.7** | 314.5 | 337.0 | 519.5 | 3.7% | 0.004 | 0.000 | 42.2 | 0.000 |
| **Pool grande (64 superpáginas, 50k vivos)**| **352.5** | 321.5 | 517.0 | 586.5 | 15.8% | 0.006 | 0.000 | 42.0 | 0.000 |
| **Hole destroy + reuse** | **364.6** | 357.0 | 521.5 | 545.5 | 8.3% | 0.004 | 0.000 | 42.0 | 1.000 |
| **Hot allocate + free (con ancla)** | **408.4** | 400.0 | 537.5 | 636.5 | 4.5% | 0.004 | 0.000 | 42.0 | 0.000 |
| **Commit + reclaim agresivo** | **4.121.9** | 3.691.0 | 5.582.5 | 6.617.5 | 15.4% | 0.004 | 2.000 | 42.2 | 0.000 |
| **Commit + reclaim agresivo (con mprotect)** | **3.826.1** | 3.699.0 | 4.362.0 | 6.057.5 | 3.9% | 0.004 | 3.000 | 42.2 | 0.000 |
| *Línea base: Box<[u8;64]> alloc + free* | 106.3 | 106.0 | 123.0 | 151.0 | 1.5% | 1.000 | 0.000 | 0.0 | 0.000 |
| *Línea base: Box ráfaga 960+960 (por op)* | 84.3 | 61.5 | 171.0 | 229.5 | 10.4% | 0.501 | 0.000 | 0.0 | 0.000 |

### 4.2 Métricas de consumo de memoria y Working Set (Pool 64 superpáginas / 4.0 MiB reservados)

Con 50.000 objetos vivos de 64 B (3.05 MiB de carga útil neta), se midió la memoria comprometida real y el impacto en Working Set (WS) / Resident Set Size (RSS):

| Estado y Política de Reclamación | Comprometido | Accesible | Δ WS / RSS | Δ Memoria Privada |
|---|---:|---:|---:|---:|
| **Agresivo: 50.000 objetos vivos** | 3.26 MiB | 3.26 MiB | +4.17 MiB | +4.35 MiB |
| **Agresivo: 25.000 vivos intercalados** | 3.26 MiB | 3.26 MiB | +3.79 MiB | +3.75 MiB |
| **Agresivo: 0 vivos (vaciado ordinario)** | 0.21 MiB | 0.21 MiB | +0.73 MiB | +0.81 MiB |
| **Agresivo: 0 vivos tras `reclaim_all`** | 0.21 MiB | 0.21 MiB | +0.73 MiB | +0.81 MiB |
| **Diferido `keep=8`: 50.000 objetos vivos** | 3.26 MiB | 3.26 MiB | +4.23 MiB | +4.36 MiB |
| **Diferido `keep=8`: 25.000 intercalados** | 3.26 MiB | 3.26 MiB | +3.85 MiB | +3.86 MiB |
| **Diferido `keep=8`: 0 vivos ordinario** | 0.24 MiB | 0.24 MiB | +0.83 MiB | +1.07 MiB |
| **Diferido `keep=8`: 0 tras `reclaim_all`** | 0.21 MiB | 0.21 MiB | +0.80 MiB | +1.04 MiB |

### 4.3 Conclusiones empíricas y delimitación metodológica

1. **Separación de Revalidación y Lectura**:
   - La revalidación pura en `PhysicalPool` toma **14.5 ns/op** (mediana 13.5 ns).
   - La revalidación compacta de 32 bits vía `CompactPhysicalPool` toma **22.7 ns/op** (mediana 22.0 ns, CV 1.0%), comprobando pertenencia de pool, estado de subpágina física (`PageState::Committed`), avance generacional y límites de capacidad.
   - La revalidación compacta de 64 bits vía `CompactPhysicalPool64` toma **23.0 ns/op** (mediana 22.5 ns, CV 0.7%), con coste equivalente a la variante de 32 bits.
   - La revalidación combinada con lectura de campo de 64 bits (`pool.read_int`) toma **53.1 ns/op** (mediana 51.5 ns), evidenciando que ~38 ns corresponden a la desreferenciación en memoria virtual y lectura tipada.
2. **Corrección del Acumulador Estadístico**:
   - Se corrigió el agregador de contadores en `nexo-physical-bench` para acumular a través de todas las corridas (`RUNS = 7`) en lugar de sobreescribirse con la última corrida, dividiendo exactamente por el total de operaciones ejecutadas (`RUNS × ops`).
3. **Eficacia de amortización de llamadas al SO**: En la política `Deferred` (`keep=1`), la latencia es de **321.7 ns/op** con **0.000 llamadas al SO/op**, mientras que la política agresiva requiere **4.121.9 ns/op** debido a 2 llamadas al kernel por operación (`VirtualAlloc`/`VirtualFree`).
4. **Devolución de memoria**: Al descender de 50.000 a 0 objetos vivos, la memoria comprometida desciende de **3.26 MiB a 0.21 MiB** (reducción del 93.5%), confirmando la descommitación física efectiva hacia el sistema operativo.
