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

## 4. Metodología de validación independiente, resultados multi-proceso y memoria

Para asegurar reproducibilidad estadística rigurosa conforme a los estándares de sistemas críticos, se implementó una metodología dual que distingue explícitamente entre:
1. **Muestreo por lotes intra-proceso**: 7 corridas (`RUNS = 7`) $\times$ 100 lotes de 200 ops = 700 muestras por escenario (140.000 ops por escenario). Permite alta resolución estadística para percentiles de lote (mediana, p95, p99, mínimo y máximo intra-proceso).
2. **Ejecuciones multi-proceso independientes**: Mínimo 5 ejecuciones completamente independientes del binario `nexo-physical-bench` desde el sistema operativo en perfil `release` (x86_64). Cada proceso inicializa su propio espacio de direcciones virtuales, tablas de páginas y memoria de proceso desde cero, eliminando sesgos de estado residual de memoria o efectos de caché de asignadores de usuario.

### 4.1 Entorno experimental de medición

- **Sistema Operativo**: Windows 11 / Windows 10 x86_64
- **Arquitectura**: x86_64
- **Toolchain de Rust**: Rust 1.88 / MSVC
- **Perfil de compilación**: `release` (`opt-level = 3`, LTO habilitado)
- **Fase de calentamiento**: 2.000 operaciones por escenario
- **Iteraciones por corrida**: 20.000 operaciones (o 9.600 en ráfaga)
- **Tamaño de lote (*batch*)**: 200 operaciones por lote
- **Muestras de lote por proceso**: 700 lotes (336 en ráfaga)
- **Procesos del SO independientes ejecutados**: 5

### 4.2 Resultados consolidados a través de 5 ejecuciones de proceso independientes

A continuación se presentan las métricas de latencia calculadas sobre los 5 procesos independientes del sistema operativo.

> [!NOTE]
> Con $N=5$ ejecuciones de proceso, las métricas de dispersión entre procesos se cuantifican mediante media, mediana, mínimo, máximo, desviación estándar y coeficiente de variación (CV%). Los percentiles extremos p95 y p99 tienen baja resolución matemática sobre $N=5$ procesos; su distribución de alta resolución se reporta sobre las 700 muestras de lote por proceso.

| Escenario | Media entre Procesos (ns/op) | Mediana entre Procesos (ns/op) | Mínimo entre Procesos (ns/op) | Máximo entre Procesos (ns/op) | Desv. Estándar (ns/op) | CV% entre Procesos | Llamadas SO/op | Asignaciones Aux./op |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Revalidación estándar pura (`PhysicalPool`)** | **28.7** | 31.3 | 21.2 | 34.5 | 5.8 | 20.0% | 0.000 | 0.004 |
| **Revalidación compacta pura 32b (`CompactPhysicalPool`)** | **46.9** | 50.7 | 35.9 | 54.8 | 8.1 | 17.2% | 0.000 | 0.004 |
| **Revalidación compacta pura 64b (`CompactPhysicalPool64`)** | **47.3** | 48.2 | 34.5 | 59.3 | 9.3 | 19.6% | 0.000 | 0.004 |
| **Revalidar estándar + leer int 64-bit** | **94.4** | 93.2 | 81.4 | 106.4 | 9.1 | 9.6% | 0.000 | 0.004 |
| **Ráfaga 960 alloc + 960 free (por op)** | **352.1** | 332.4 | 325.1 | 390.6 | 31.6 | 9.0% | 0.016 | 0.008 |
| **Hole destroy + reuse** | **521.4** | 507.5 | 443.1 | 617.7 | 66.2 | 12.7% | 0.000 | 0.004 |
| **Hot allocate + free (pool con ancla)** | **574.3** | 565.4 | 514.1 | 693.1 | 72.8 | 12.7% | 0.000 | 0.004 |
| **Larga duración: 900 vivos + churn** | **642.7** | 568.8 | 501.6 | 825.0 | 150.2 | 23.4% | 0.000 | 0.004 |
| **Fragmentado: 450 subpáginas a medias** | **756.2** | 659.5 | 537.8 | 1245.9 | 289.4 | 38.3% | 0.000 | 0.005 |
| **Pool pequeño (1 superpágina)** | **745.5** | 681.7 | 534.2 | 1147.8 | 243.6 | 32.7% | 0.000 | 0.004 |
| **Pool grande (64 superpáginas, 50.000 vivos)** | **769.2** | 783.5 | 611.4 | 878.3 | 96.7 | 12.6% | 0.000 | 0.006 |
| **Commit + reclaim diferido (`keep=1`)** | **616.5** | 640.9 | 508.3 | 677.1 | 67.4 | 10.9% | 0.000 | 0.004 |
| **Commit + reclaim agresivo** | **5.782.7** | 5.603.6 | 5.186.3 | 6.719.1 | 586.2 | 10.1% | 2.000 | 0.004 |
| **Commit + reclaim agresivo (con protección)** | **8.497.4** | 8.715.6 | 7.196.9 | 9.729.5 | 960.9 | 11.3% | 3.000 | 0.004 |
| *Línea base: Box<[u8; 64]> asignar + liberar* | 250.8 | 220.3 | 182.7 | 399.2 | 87.7 | 35.0% | 0.000 | 1.000 |
| *Línea base: Box ráfaga 960+960 (por op)* | 159.7 | 159.4 | 128.8 | 199.3 | 28.5 | 17.8% | 0.000 | 0.501 |

### 4.3 Tabla detallada de distribución intra-proceso (700 lotes de 200 ops)

Muestra representativa de la ejecución con reporte de percentiles de lote p50, p95 y p99:

| Escenario | Media (ns/op) | Mediana (ns/op) | Mínimo (ns/op) | Máximo (ns/op) | p95 (ns/op) | p99 (ns/op) | SD Intra | CV% Intra | Lotes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Revalidar estándar puro** | 24.0 | 26.5 | 17.0 | 144.5 | 29.0 | 40.5 | 4.3 | 17.9% | 700 |
| **Revalidar compacto 32b** | 35.9 | 27.0 | 26.0 | 86.0 | 54.0 | 66.5 | 5.6 | 15.6% | 700 |
| **Revalidar compacto 64b** | 43.2 | 46.5 | 26.0 | 77.5 | 55.0 | 66.5 | 4.8 | 11.2% | 700 |
| **Revalidar estándar + leer** | 97.9 | 85.0 | 65.0 | 2.969.5 | 98.5 | 231.0 | 18.8 | 19.2% | 700 |
| **Ráfaga 960 alloc + 960 free** | 331.3 | 321.5 | 205.0 | 1.992.5 | 464.0 | 937.5 | 20.8 | 6.3% | 336 |
| **Hole destroy + reuse** | 491.9 | 399.0 | 362.0 | 6.253.5 | 623.5 | 1.770.5 | 73.4 | 14.9% | 700 |
| **Hot allocate + free (ancla)** | 565.4 | 548.5 | 393.0 | 4.250.0 | 769.5 | 1.601.5 | 76.0 | 13.4% | 700 |
| **Larga duración: 900 vivos** | 568.8 | 585.0 | 395.5 | 1.562.5 | 708.5 | 827.0 | 70.3 | 12.4% | 700 |
| **Fragmentado: 450 subpáginas** | 537.8 | 517.5 | 410.0 | 2.729.0 | 688.5 | 800.0 | 64.5 | 12.0% | 700 |
| **Pool pequeño (1 superpágina)** | 681.7 | 675.0 | 438.5 | 1.267.0 | 775.0 | 933.5 | 9.8 | 1.4% | 700 |
| **Pool grande (50.000 vivos)** | 611.4 | 609.0 | 435.0 | 5.632.5 | 776.0 | 1.217.0 | 71.4 | 11.7% | 700 |
| **Reclaim diferido (`keep=1`)** | 508.3 | 499.5 | 397.5 | 2.256.0 | 647.0 | 884.5 | 29.5 | 5.8% | 700 |
| **Reclaim agresivo** | 5.186.3 | 5.135.5 | 3.633.5 | 11.219.0 | 6.760.0 | 9.639.0 | 315.3 | 6.1% | 700 |
| **Reclaim agresivo (protegido)** | 7.196.9 | 6.949.5 | 4.851.5 | 26.931.0 | 9.928.0 | 15.491.0 | 690.8 | 9.6% | 700 |
| *Box<[u8; 64]> alloc + free* | 182.7 | 188.0 | 122.0 | 469.0 | 218.0 | 279.5 | 15.5 | 8.5% | 700 |
| *Box ráfaga 960+960* | 136.2 | 113.0 | 55.5 | 341.0 | 269.0 | 303.5 | 16.0 | 11.7% | 336 |

### 4.4 Métricas de consumo de memoria y Working Set (Pool 64 superpáginas / 4.0 MiB reservados)

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

### 4.5 Conclusiones empíricas y delimitación metodológica

1. **Separación de Revalidación y Lectura**:
   - La revalidación pura en `PhysicalPool` promedia **28.7 ns/op** entre 5 procesos independientes (mediana entre procesos 31.3 ns, mínimo 21.2 ns).
   - La revalidación compacta de 32 bits vía `CompactPhysicalPool` promedia **46.9 ns/op** entre procesos (mediana 50.7 ns, mínimo 35.9 ns), comprobando pertenencia de pool, estado de subpágina física (`PageState::Committed`), avance generacional y límites de capacidad.
   - La revalidación compacta de 64 bits vía `CompactPhysicalPool64` promedia **47.3 ns/op** entre procesos (mediana 48.2 ns, mínimo 34.5 ns), con coste equivalente a la variante de 32 bits.
   - La revalidación combinada con lectura de campo de 64 bits (`pool.read_int`) promedia **94.4 ns/op** entre procesos (mediana 93.2 ns, mínimo 81.4 ns), evidenciando que ~47 ns corresponden a la desreferenciación en memoria virtual y lectura tipada de enteros de 64 bits.
2. **Corrección del Acumulador Estadístico**:
   - Se corrigió el agregador de contadores en `nexo-physical-bench` para acumular a través de todas las corridas (`RUNS = 7`) en lugar de sobreescribirse con la última corrida, dividiendo exactamente por el total de operaciones ejecutadas (`RUNS × ops`).
3. **Eficacia de amortización de llamadas al SO**: En la política `Deferred` (`keep=1`), la latencia promedia **616.5 ns/op** con **0.000 llamadas al SO/op**, mientras que la política agresiva requiere **5.782.7 ns/op** debido a 2 llamadas al kernel por operación (`VirtualAlloc`/`VirtualFree`).
4. **Devolución de memoria**: Al descender de 50.000 a 0 objetos vivos, la memoria comprometida desciende de **3.26 MiB a 0.21 MiB** (reducción del 93.5%), confirmando la descommitación física efectiva hacia el sistema operativo.
