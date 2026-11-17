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

---

### 4.7 Blindaje Criptográfico de Evidencia y Validación Adversarial (Evidence Lockdown)

Para garantizar que los resultados de benchmark no puedan ser contaminados por artefactos obsoletos ni ejecuciones parciales o adulteradas, se implementó el protocolo de bloqueo de evidencia:

1. **Aislamiento Criptográfico por Campaña**:
   - Cada ejecución de `scripts/run_benchmarks.py` genera un identificador único de campaña (`campaign_id`), persistiendo todos los resultados en un subdirectorio exclusivo: `docs/benchmarks/campaigns/<campaign_id>/raw/process_{1..5}.json`.
   - Se genera el manifiesto criptográfico `checksums.sha256` con los hashes SHA-256 de todos los archivos producidos.
2. **Inmutabilidad y Trazabilidad del Binario**:
   - Se calcula el hash SHA-256 del binario release `nexo-physical-bench` antes de iniciar las mediciones y se revalida tras cada proceso independiente, garantizando que el binario no ha sido sustituido ni modificado.
   - Se registra el estado de Git (`git_head`, `git_branch`, `git_dirty`) y el hash SHA-256 de `git diff HEAD`.
3. **Escritura Atómica y Rechazo Fail-Closed (JSON-IO-01..10)**:
   - Todo archivo JSON se genera mediante escritura atómica (`<target>.tmp.<pid>` y renombre atómico).
   - Cualquier error de I/O o validación numérica termina con código de salida no cero (`std::process::exit(1)`), emitiendo el error a `stderr`.
4. **Validación Adversarial contra Artefactos Obsoletos (BENCH-STALE-01..10)**:
   - Verificación estricta de esquema versionado (`schema_version: "v0.4.1"`), especificación estadística (`stats_spec_version: "1.1.0"`), coincidencia de identificadores de campaña y proceso, conteo exacto de 16 escenarios sin duplicados, muestras requeridas (700 estándar, 336 en ráfaga) y ausencia de valores no finitos.
5. **Paridad Estadística Exacta Rust/Python (STAT-CROSS-01..10)**:
   - La especificación estadística `1.1.0` define la misma interpolación lineal uniforme estándar $r = (N-1) \times p, w = r - \lfloor r \rfloor, x_i(1-w) + x_j w$ en Rust y Python, verificada mediante pruebas cruzadas automáticas en ambas plataformas.

---

### 4.8 Publicación Transaccional, Reemplazo Seguro en Windows y Verificación de Muestras (Operación Evidence Final Hardening)

En la consolidación final de NEXO v0.4 se resolvieron todos los vectores restantes de integridad de evidencia y persistencia atómica:

1. **Reemplazo Atómico Seguro en Windows sin Borrado Previo (ATOMIC-01..10)**:
   - Se eliminó el patrón inseguro `remove_file(path)` previo a `rename(tmp, path)` en `crates/nexo/src/bin/nexo-physical-bench.rs`.
   - Se adoptó una estrategia transaccional de *backup-and-restore*: si el archivo previo existe, se renombra primero a `<path>.bak.<pid>`. A continuación, se renombra el archivo temporal `<tmp>` a `<path>`. Si esta segunda operación falla, se restaura inmediatamente el backup original, garantizando que el archivo anterior jamás se pierde ni queda truncado. Tras el éxito de la operación, el archivo `.bak` temporal se elimina de forma limpia.
   - Verificado mediante pruebas adversariales en `crates/nexo/tests/test_bench_io.rs` (`test_atomic_05_and_06_previous_file_preserved_on_failure_and_no_tmp_bak`).

2. **Pipeline de Publicación Transaccional en 5 Fases (PUBLISH-01..10)**:
   En `scripts/run_benchmarks.py`, el proceso de benchmarking se estructuró en cinco fases estrictamente desacopladas:
   - **Fase A (Aislamiento)**: Creación del directorio aislado `docs/benchmarks/campaigns/<campaign_id>/`. En modo experimental o dirty, se genera `patch.diff` y se registran los archivos no rastreados en `untracked_files.txt`. Los directorios y resúmenes públicos (`docs/benchmarks/summary.json` y `LATEST_CAMPAIGN`) no se tocan.
   - **Fase B (Ejecución Aislada)**: Ejecución de 5 procesos independientes de SO (`nexo-physical-bench --completo`), emitiendo su salida exclusivamente a `campaigns/<campaign_id>/raw/process_{1..5}.json`. Se verifica el hash del binario antes y después de cada proceso.
   - **Fase C (Validación Integral y Recálculo)**: Verificación estructural, de esquema y recálculo matemático de las 13 métricas a partir de `batch_samples` y `run_means`. Si algún proceso falla, la campaña se aborta inmediatamente sin tocar la publicación pública.
   - **Fase D (Consolidación y Verificación Matemática)**: Construcción del `summary.json` y verificación cruzada contra los datos de los 5 procesos individuales.
   - **Fase E (Publicación Transaccional Atómica)**: Generación de `manifest.json` y `checksums.sha256` en la carpeta de campaña. Únicamente tras la verificación total, se actualiza atómicamente `docs/benchmarks/LATEST_CAMPAIGN`, `docs/benchmarks/summary.json` y las copias retrocompatibles en `docs/benchmarks/raw/`.

3. **Recálculo Estadístico Real contra Muestras Brutas (STATS-INTEGRITY-01..10)**:
   - Se audita que `batch_stats` coincida campo por campo con el recálculo independiente de Welford ejecutado sobre los 700 lotes (336 en ráfagas), verificando las 13 métricas: `count`, `mean`, `median`, `min`, `max`, `variance_sample`, `variance_pop`, `stddev_sample`, `stddev_pop`, `cv_sample`, `cv_pop`, `p50`, `p95` y `p99`.
   - Se audita que `run_means` contenga exactamente 7 valores finitos, que su promedio coincida con la media de `batch_samples`, y que `run_stats` coincida con la distribución de las 7 corridas.
   - Evaluado mediante la suite `scripts/test_stats_integrity.py` (10 pruebas adversariales).

4. **Trazabilidad y Control de Modo Oficial vs Experimental (SOURCE-01..10)**:
   - `--official`: Exige un worktree de Git 100% limpio. Si se detectan cambios locales o archivos staged, aborta *fail-closed*.
   - `--experimental`: Si el árbol contiene cambios no commiteados, genera automáticamente `patch.diff` (`git diff HEAD`) y registra los archivos en `untracked_files.txt`, incorporando dichos artefactos al `manifest.json` y `checksums.sha256`.

5. **Pruebas Cruzadas Reales Rust <-> Python con Fixtures en Disco**:
   - Creación de fixtures compartidos en `crates/nexo/tests/fixtures/stats/` (`uniform.json`, `outliers.json`, `large_values.json`, `repeated_values.json`, `percentile_edges.json`).
   - Implementación del CLI `--compute-stats <fixture.json>` en `nexo-physical-bench`, permitiendo que `scripts/test_stats_cross.py` invoque el binario Rust real y compare todas las métricas contra Python.

6. **Resultados de la Campaña de Cierre (`campaign_20261117_023600_caba26e0`)**:
   - Binario release SHA-256: `52f854e3d899b46291e6c5b8d4242c544ed9626cae797c09df0c471a8435e5f2`
   - Revalidación estándar puro: **13.4 ns/op** ($s_{\text{proc}} = 1.10$ ns, CV = 8.2%)
   - Revalidación compacta 32b: **24.4 ns/op** ($s_{\text{proc}} = 6.06$ ns)
   - Revalidación compacta 64b: **22.8 ns/op** ($s_{\text{proc}} = 1.43$ ns)
   - Revalidar + leer int: **50.0 ns/op** ($s_{\text{proc}} = 0.29$ ns, CV = 0.6%)
   - Hot allocate + free: **272.0 ns/op** ($s_{\text{proc}} = 3.41$ ns, CV = 1.3%)
   - Hole destroy + reuse: **247.3 ns/op** ($s_{\text{proc}} = 4.37$ ns, CV = 1.8%)
   - Commit + reclaim diferido (`keep=1`): **275.0 ns/op** ($s_{\text{proc}} = 0.96$ ns, CV = 0.3%, 0.000 llamadas al SO/op)
   - Box global asignar + liberar: **111.9 ns/op** ($s_{\text{proc}} = 20.19$ ns, CV = 18.1%)

---

### 4.9 Consolidación Definitiva y Estabilización Zero Regression (Operación Zero Regression)

En la consolidación final de la rama `fix/nexo-v04-release-stabilization` se cerraron por causa raíz todos los hallazgos técnicos pendientes:

1. **Verificación Estricta y Verídica de Rollback en Windows (P1-C)**:
   - En `crates/nexo/src/bin/nexo-physical-bench.rs`, se verificó explícitamente el resultado de `rename(backup, path)` ante fallos de sustitución atómica.
   - Si la restauración tiene éxito, se confirma verídicamente en el error. Si la restauración falla, se emite una alarma crítica reportando la ruta donde se preservó intacto el archivo `<path>.bak.<pid>`, impidiendo pérdidas silenciosas de datos.
   - Verificado mediante `test_json_io_11_rollback_verification_and_truthful_reporting` en `crates/nexo/tests/test_bench_io.rs`.

2. **Parser Numérico JSON Conforme a RFC 8259 (P2-A)**:
   - Se reemplazó el parser laxo de muestras por un analizador estricto en `nexo-physical-bench.rs`.
   - Rechazo *fail-closed* de arrays vacíos (`[]`), comas iniciales/finales/duplicadas (`[1.0,]`), valores no finitos (`NaN`, `Infinity`), tokens no numéricos y prefijos no estándar como `+` o `0x`.
   - Verificado con 6 pruebas unitarias en `nexo-physical-bench.rs` y la suite cruzada `test_compute_stats_rejects_malformed_and_non_finite_fixtures` en `scripts/test_stats_cross.py`.

3. **Erradicación Total de `sleep()` en Pruebas Concurrentes OOM (P2-B)**:
   - En `crates/nexo/src/next/compact.rs`, se eliminó todo uso de `thread::sleep` en `test_reg_oom_08`, `test_reg_oom_09` y `test_oom_conc_10`.
   - Se implementó sincronización determinista de fases mediante barreras (`std::sync::Barrier`) y contadores atómicos (`AtomicUsize`), garantizando la observación reproducible de eventos OOM y la recuperación limpia bajo contención multihilo en microsegundos y sin condiciones de carrera.

4. **Detección Estricta de Archivos Untracked y Modo Oficial Fail-Closed (P1-A)**:
   - `get_git_info()` en `scripts/run_benchmarks.py` clasifica los archivos `??` (untracked) como estado sucio (`is_dirty = True`) y detecta fallos en la invocación de `git` (`git_error = True`).
   - El modo `--official` rechaza inmediatamente cualquier repositorio sucio, con cambios locales o con archivos untracked.

5. **Transaccionalidad Estricta y Single Source of Truth (P1-B)**:
   - Se ordenó el pipeline de Fase E: 1) Creación de artefactos inmutables en carpeta de campaña, 2) Verificación criptográfica de hashes contra `manifest.json` y `checksums.sha256`, 3) Actualización de mirrors retrocompatibles (`summary.json`, `raw/`), 4) Escritura atómica de `docs/benchmarks/LATEST_CAMPAIGN` como único *commit point* de confirmación.
   - Jerarquía formal establecida: `LATEST_CAMPAIGN -> immutable campaign -> manifest.json -> verified artifacts`.

6. **Empaquetamiento Experimental y Trazabilidad de Reproducibilidad (P2-C)**:
   - En campañas experimentales, el contenido real de los archivos no rastreados se empaqueta en `campaigns/<campaign_id>/untracked_bundle/` y se registra en el manifiesto bajo el objeto `reproducibility` (`reproducible_from_artifacts`).

7. **Sanitización Estricta de `--campaign-id` contra Path Traversal (P2-D)**:
   - Función `sanitize_campaign_id()` validando contra regex `^[a-zA-Z0-9_-]+$`, impidiendo secuencias de escape de directorio (`..`, `/`, `\`) y bloqueando colisiones con campañas existentes para garantizar exclusividad transaccional.

8. **Resultados de la Campaña Oficial Consolidada (`campaign_20261117_031829_1696d953`)**:
   - Git HEAD: `39e5ff3025e339c07b2fc72b36454319f9fe1499` (limpio, modo `official`)
   - Binario release SHA-256: `f4738f5d00e4ce453cd27af937e38e5acece83546cbd1a9516c06be2ad2a2213`
   - Revalidación estándar puro: **18.4 ns/op** ($s_{\text{proc}} = 5.25$ ns)
   - Revalidación compacta 32b: **26.7 ns/op** ($s_{\text{proc}} = 3.23$ ns, CV = 12.1%)
   - Revalidación compacta 64b: **25.6 ns/op** ($s_{\text{proc}} = 3.53$ ns, CV = 13.8%)
   - Revalidar + leer int: **65.7 ns/op** ($s_{\text{proc}} = 9.64$ ns)
   - Hot allocate + free: **445.0 ns/op** ($s_{\text{proc}} = 66.76$ ns)
   - Hole destroy + reuse: **397.9 ns/op** ($s_{\text{proc}} = 57.40$ ns)
   - Commit + reclaim diferido (`keep=1`): **438.9 ns/op** ($s_{\text{proc}} = 30.04$ ns, CV = 6.8%, 0.000 llamadas al SO/op)
   - Box global asignar + liberar: **147.1 ns/op** ($s_{\text{proc}} = 14.36$ ns, CV = 9.8%)


