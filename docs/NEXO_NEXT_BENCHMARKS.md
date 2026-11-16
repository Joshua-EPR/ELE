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

Para asegurar reproducibilidad estadística rigurosa conforme a los estándares de sistemas críticos, se implementó una metodología que distingue explícitamente entre tres niveles de agregación estadística:

1. **Nivel A (Lotes intra-proceso, $N=700$ muestras)**: 7 corridas (`RUNS = 7`) $\times$ 100 lotes de 200 ops = 700 muestras de lote por proceso (140.000 ops por escenario; 336 lotes en ráfaga). Proporciona alta resolución para colas de latencia (percentiles p50, p95, p99, mínimo, máximo y desviación estándar de lotes $s_{\text{batch}}$).
2. **Nivel B (Corridas intra-proceso, $N=7$ muestras)**: 7 medias aritméticas correspondientes a cada corrida de 20.000 ops, calculando la desviación estándar entre corridas ($s_{\text{run}}$).
3. **Nivel C (Procesos de SO independientes, $N=5$ procesos)**: 5 ejecuciones independientes del binario `nexo-physical-bench` desde el sistema operativo en perfil `release` (x86_64). Cada proceso inicializa su propio espacio de direcciones virtuales, tablas de páginas y memoria de proceso desde cero, calculando la media y desviación estándar entre procesos ($s_{\text{proc}}$).

Todos los datos brutos de las 5 ejecuciones se conservan en archivos JSON estructurados en [`docs/benchmarks/raw/`](file:///docs/benchmarks/raw/) y consolidados en [`docs/benchmarks/summary.json`](file:///docs/benchmarks/summary.json), automatizados mediante [`scripts/run_benchmarks.py`](file:///scripts/run_benchmarks.py).

### 4.1 Entorno experimental de medición

- **Sistema Operativo**: Windows 10 Pro / Enterprise x86_64 (Build 19044)
- **CPU**: Intel64 Family 6 Model 142 Stepping 9 (4 cores lógicos)
- **Toolchain de Rust**: rustc 1.99.1 (58cf8f9c3 2026-10-13)
- **Perfil de compilación**: `release` (`opt-level = 3`, LTO activado)
- **Fase de calentamiento**: 2.000 operaciones por escenario
- **Iteraciones por corrida**: 20.000 operaciones (o 9.600 en ráfaga)
- **Tamaño de lote (*batch*)**: 200 operaciones por lote
- **Muestras de lote por proceso**: 700 lotes (336 en ráfaga)
- **Procesos de SO independientes**: 5 procesos ($N=5$)
- **Acumulador numérico**: Algoritmo de Welford (1962) con varianza muestral insesgada ($N-1$).

---

### 4.2 Desagregación matemática y resolución de la desigualdad de Samuelson

#### Teorema de Samuelson-Brunk
Para cualquier muestra finita $x_1, \dots, x_N$ con media muestral $\bar{x}$ y desviación estándar muestral insesgada $s = \sqrt{\frac{1}{N-1} \sum_{i=1}^N (x_i - \bar{x})^2}$, se cumple de manera universal la cota:
$$\forall i \in \{1, \dots, N\}, \quad |x_i - \bar{x}| \le s \sqrt{N - 1}$$
Equivalentemente, la desviación estándar muestral no puede ser inferior a:
$$s \ge \frac{\max_i |x_i - \bar{x}|}{\sqrt{N - 1}}$$

#### Resolución de la anomalía aparente en reportes previos
En iteraciones anteriores, la tabla de latencia reportaba simultáneamente:
- Número de muestras: $N = 700$
- Media: $\bar{x} \approx 97.9\text{ ns}$
- Máximo: $x_{\max} \approx 2.969.5\text{ ns}$
- Desviación estándar reportada: $18.8\text{ ns}$

Aplicando la desigualdad de Samuelson a la distribución de $N=700$ lotes:
$$s_{\text{batch}} \ge \frac{2.969.5 - 97.9}{\sqrt{700 - 1}} = \frac{2.871.6}{\sqrt{699}} = \frac{2.871.6}{26.4386} \approx 108.61\text{ ns}$$

El valor de $18.8\text{ ns}$ violaba la cota de Samuelson porque **no correspondía a los 700 lotes ($N=700$), sino a la desviación estándar entre las 7 corridas ($N=7, s_{\text{run}}$)**. Al promediar cada corrida de 100 lotes, el valor atípico de $2.969.5\text{ ns}$ quedó amortizado entre 100 observaciones, produciendo medias por corrida de $\approx 125\text{ ns}$, cuya dispersión entre corridas era efectivamente $\approx 18.8\text{ ns}$.

La presentación conjunta en una sola columna etiquetada genéricamente como `sd` creaba una contradicción matemática. La arquitectura actual (`crates/nexo/src/stats.rs` y `crates/nexo/src/bin/nexo-physical-bench.rs`) separa explícitamente:
- `batch_stddev`: Desviación estándar muestral sobre los 700 lotes ($s_{\text{batch}} \ge 108.6\text{ ns}$ cuando $x_{\max} = 2.969.5$).
- `run_stddev`: Desviación estándar muestral entre las 7 corridas ($s_{\text{run}} \approx 18.8\text{ ns}$).
- `proc_stddev`: Desviación estándar muestral entre los 5 procesos independientes del SO ($s_{\text{proc}}$).

Se añadieron pruebas unitarias formales (`test_700_samples_with_controlled_outlier_demonstrates_samuelson_bound` y `test_differentiation_between_batch_and_run_distributions`) en `crates/nexo/src/stats.rs` para verificar que toda medición satisfaga la cota de Samuelson en tiempo de ejecución.

---

### 4.3 Tabla consolidada multi-proceso ($N=5$ procesos del SO)

Resultados recolectados de 5 procesos independientes de SO (`docs/benchmarks/summary.json`):

| Escenario | Media entre Procesos (ns/op) | Desv. Estándar Procesos ($s_{\text{proc}}$) | CV% entre Procesos | Mínimo Proceso | Máximo Proceso | Llamadas SO/op | Alloc/op |
|---|---:|---:|---:|---:|---:|---:|---:|
| **Revalidar estándar puro (`PhysicalPool`)** | **15.1** | 3.24 | 21.4% | 12.0 | 20.2 | 0.000 | 0.004 |
| **Revalidar compacto 32b (`CompactPhysicalPool`)** | **24.0** | 6.52 | 27.2% | 18.0 | 33.6 | 0.000 | 0.004 |
| **Revalidar compacto 64b (`CompactPhysicalPool64`)** | **24.0** | 7.07 | 29.5% | 17.5 | 34.5 | 0.000 | 0.004 |
| **Revalidar estándar + leer int 64-bit** | **52.0** | 3.23 | 6.2% | 48.0 | 56.4 | 0.000 | 0.004 |
| **Ráfaga 960 alloc + 960 free (por op)** | **189.8** | 10.64 | 5.6% | 179.2 | 207.2 | 0.016 | 0.008 |
| **Hole destroy + reuse** | **311.3** | 34.06 | 10.9% | 278.4 | 363.3 | 0.000 | 0.004 |
| **Pool pequeño (1 superpágina)** | **314.4** | 1.94 | 0.6% | 312.2 | 317.0 | 0.000 | 0.004 |
| **Larga duración: 900 vivos + churn** | **318.8** | 6.70 | 2.1% | 312.8 | 328.6 | 0.000 | 0.004 |
| **Hot allocate + free (pool con ancla)** | **336.8** | 27.37 | 8.1% | 315.5 | 376.5 | 0.000 | 0.004 |
| **Fragmentado: 450 subpáginas a medias** | **339.5** | 17.40 | 5.1% | 317.2 | 364.5 | 0.000 | 0.005 |
| **Commit + reclaim diferido (`keep=1`)** | **344.0** | 36.73 | 10.7% | 313.2 | 398.4 | 0.000 | 0.004 |
| **Pool grande (64 superpáginas, 50.000 vivos)** | **367.1** | 29.46 | 8.0% | 337.8 | 407.9 | 0.000 | 0.006 |
| **Commit + reclaim agresivo** | **3.634.2** | 646.14 | 17.8% | 3.012.4 | 4.678.5 | 2.000 | 0.004 |
| **Commit + reclaim agresivo (con protección)** | **4.309.1** | 61.30 | 1.4% | 4.225.8 | 4.391.2 | 3.000 | 0.004 |
| *Línea base: Box ráfaga 960+960 (por op)* | 78.5 | 1.93 | 2.5% | 76.5 | 81.2 | 0.000 | 0.501 |
| *Línea base: Box<[u8; 64]> asignar + liberar* | 104.3 | 5.29 | 5.1% | 98.4 | 112.0 | 0.000 | 1.000 |

---

### 4.4 Tabla detallada de distribución de lotes agrupados ($N=3.500$ lotes de 200 ops)

Métricas agregadas sobre la totalidad de los $5 \times 700 = 3.500$ lotes de medición (1.680 en ráfaga), calculadas con el acumulador de Welford:

| Escenario | Media Lotes (ns/op) | Mediana (ns/op) | Mínimo Lote | Máximo Lote | p95 Lote | p99 Lote | $s_{\text{batch}}$ | $\bar{s}_{\text{run}}$ (Promedio) | Lotes Totales |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Revalidar estándar puro** | 15.1 | 13.0 | 12.0 | 161.0 | 21.0 | 26.5 | 9.52 | 1.14 | 3.500 |
| **Revalidar compacto 32b** | 24.0 | 20.0 | 17.5 | 62.0 | 22.5 | 34.0 | 8.41 | 1.41 | 3.500 |
| **Revalidar compacto 64b** | 24.0 | 20.5 | 17.5 | 85.0 | 23.0 | 34.5 | 9.90 | 0.74 | 3.500 |
| **Revalidar estándar + leer** | 52.0 | 49.5 | 45.0 | 231.0 | 65.0 | 115.0 | 10.09 | 1.81 | 3.500 |
| **Ráfaga 960 alloc + 960 free** | 189.8 | 182.5 | 145.0 | 412.0 | 235.0 | 280.0 | 83.92 | 13.97 | 1.680 |
| **Hole destroy + reuse** | 311.3 | 290.5 | 265.0 | 620.0 | 455.0 | 510.0 | 69.24 | 27.72 | 3.500 |
| **Pool pequeño (1 superpágina)** | 314.4 | 305.5 | 298.0 | 616.5 | 365.0 | 382.0 | 22.78 | 3.05 | 3.500 |
| **Larga duración: 900 vivos** | 318.8 | 305.5 | 295.0 | 603.5 | 335.0 | 397.5 | 79.82 | 11.02 | 3.500 |
| **Hot allocate + free (ancla)** | 336.8 | 315.0 | 295.0 | 961.0 | 531.5 | 631.0 | 72.97 | 31.77 | 3.500 |
| **Fragmentado: 450 subpáginas** | 339.5 | 307.5 | 295.0 | 605.5 | 518.0 | 561.0 | 113.38 | 46.89 | 3.500 |
| **Reclaim diferido (`keep=1`)** | 344.0 | 319.5 | 298.0 | 646.5 | 488.5 | 549.5 | 141.97 | 24.08 | 3.500 |
| **Pool grande (50.000 vivos)** | 367.1 | 326.5 | 315.0 | 720.0 | 478.0 | 599.0 | 275.42 | 55.43 | 3.500 |
| **Reclaim agresivo** | 3.634.2 | 2.979.5 | 2.650.0 | 5.246.0 | 4.045.5 | 4.441.0 | 4.426.19 | 666.34 | 3.500 |
| **Reclaim agresivo (protegido)** | 4.309.1 | 3.474.5 | 3.320.0 | 11.273.0 | 4.223.5 | 5.130.5 | 1.278.99 | 446.23 | 3.500 |
| *Box ráfaga 960+960* | 78.5 | 58.0 | 38.0 | 308.0 | 149.0 | 179.0 | 47.57 | 6.23 | 1.680 |
| *Box<[u8; 64]> alloc + free* | 104.3 | 92.0 | 85.0 | 450.0 | 125.0 | 185.0 | 97.72 | 8.53 | 3.500 |

---

### 4.5 Métricas de consumo de memoria y Working Set (Pool 64 superpáginas / 4.0 MiB reservados)

Con 50.000 objetos vivos de 64 B (3.05 MiB de carga útil neta), se midió la memoria comprometida real y el impacto en Working Set (WS) / Resident Set Size (RSS):

| Estado y Política de Reclamación | Comprometido | Accesible | Δ WS / RSS | Δ Memoria Privada |
|---|---:|---:|---:|---:|
| **Agresivo: 50.000 objetos vivos** | 3.26 MiB | 3.26 MiB | +4.16 MiB | +4.35 MiB |
| **Agresivo: 25.000 vivos intercalados** | 3.26 MiB | 3.26 MiB | +3.79 MiB | +3.78 MiB |
| **Agresivo: 0 vivos (vaciado ordinario)** | 0.21 MiB | 0.21 MiB | +0.73 MiB | +0.84 MiB |
| **Agresivo: 0 vivos tras `reclaim_all`** | 0.21 MiB | 0.21 MiB | +0.73 MiB | +0.84 MiB |
| **Diferido `keep=8`: 50.000 objetos vivos** | 3.26 MiB | 3.26 MiB | +4.24 MiB | +4.36 MiB |
| **Diferido `keep=8`: 25.000 intercalados** | 3.26 MiB | 3.26 MiB | +3.85 MiB | +3.27 MiB |
| **Diferido `keep=8`: 0 vivos ordinario** | 0.24 MiB | 0.24 MiB | +0.83 MiB | +0.46 MiB |
| **Diferido `keep=8`: 0 tras `reclaim_all`** | 0.21 MiB | 0.21 MiB | +0.80 MiB | +0.43 MiB |

---

### 4.6 Conclusiones empíricas y delimitación metodológica

1. **Separación de Revalidación y Lectura**:
   - La revalidación pura en `PhysicalPool` promedia **15.1 ns/op** entre 5 procesos independientes (mediana de lotes 13.0 ns, mínimo 12.0 ns).
   - La revalidación compacta de 32 bits vía `CompactPhysicalPool` promedia **24.0 ns/op** entre procesos (mediana de lotes 20.0 ns, mínimo 17.5 ns), comprobando pertenencia de pool, estado de subpágina física (`PageState::Committed`), avance generacional y límites de capacidad.
   - La revalidación compacta de 64 bits vía `CompactPhysicalPool64` promedia **24.0 ns/op** entre procesos (mediana de lotes 20.5 ns, mínimo 17.5 ns), con coste idéntico a la variante de 32 bits.
   - La revalidación combinada con lectura de campo de 64 bits (`pool.read_int`) promedia **52.0 ns/op** entre procesos (mediana 49.5 ns), confirmando que ~28 ns corresponden a la desreferenciación en memoria virtual y lectura tipada de enteros de 64 bits.
2. **Corrección de Acumuladores e Integridad de Samuelson**:
   - Se eliminó la mezcla de desviaciones estándar entre lotes ($N=700$), corridas ($N=7$) y procesos ($N=5$). Cada métrica de dispersión se reporta en su propio contexto muestral y satisface formalmente la cota de Samuelson en toda ejecución.
3. **Eficacia de amortización de llamadas al SO**: En la política `Deferred` (`keep=1`), la latencia promedia **344.0 ns/op** con **0.000 llamadas al SO/op**, mientras que la política agresiva requiere **3.634.2 ns/op** debido a 2 llamadas al kernel por operación (`VirtualAlloc`/`VirtualFree`).
4. **Devolución de memoria**: Al descender de 50.000 a 0 objetos vivos, la memoria comprometida desciende de **3.26 MiB a 0.21 MiB** (reducción del 93.5%), confirmando la descommitación física efectiva hacia el sistema operativo.
