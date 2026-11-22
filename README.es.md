# ELE: Lenguaje de Programación de Sistemas Autorreconstruible

<p align="center">
  <a href="https://github.com/Joshua-EPR/ELE/actions/workflows/native-selfhosting-validation.yml"><img src="https://img.shields.io/github/actions/workflow/status/Joshua-EPR/ELE/native-selfhosting-validation.yml?branch=main&label=Native%20CI&style=flat-square" alt="Native CI"></a>
  <a href="https://github.com/Joshua-EPR/ELE/actions/workflows/docs-and-benchmarks.yml"><img src="https://img.shields.io/github/actions/workflow/status/Joshua-EPR/ELE/docs-and-benchmarks.yml?branch=main&label=Docs%20%26%20Benchmarks&style=flat-square" alt="Docs CI"></a>
  <img src="https://img.shields.io/badge/Arquitectura-x86--64-blue?style=flat-square" alt="x86-64">
  <img src="https://img.shields.io/badge/Objetivos-Windows%20PE32%2B%20%7C%20Linux%20ELF64-success?style=flat-square" alt="Objetivos">
  <img src="https://img.shields.io/badge/Runtime-Cero%20CRT-informational?style=flat-square" alt="Cero CRT">
</p>

<p align="center">
  <a href="README.md">English</a> | <b>Español</b>
</p>

---

## Introducción

**ELE** es un lenguaje de programación de sistemas experimental y autorreconstruible (self-hosting), diseñado para ofrecer seguridad determinista de memoria sin recolector de basura (garbage collector). Compila directamente a código máquina nativo (**Windows PE32+** y **Linux ELF64**) con **cero dependencias del C Runtime (CRT) o de bibliotecas estándar externas**.

A diferencia de los lenguajes que dependen de capas de runtime pesadas o enlazadores externos, ELE cuenta con un driver de compilación autónomo (`ele build`) escrito íntegramente en ELE que emite directamente imágenes ejecutables binarias, planifica la memoria de la pila (stack) y verifica la propiedad y préstamos de memoria mediante un sistema de tipos afines.

---

## ¿Por qué ELE?

- **Seguridad de memoria en compilación sin GC:** Sistema de tipos afines con elaboración determinista de liberaciones (*drop flags*), semántica de movimientos (*moves*) y comprobación estricta de préstamos (`view` para préstamos compartidos de lectura, `edit` para préstamos exclusivos de escritura).
- **Binarios nativos sin dependencias externas:** Produce ejecutables independientes extremadamente compactos (**~5 KiB**) directamente desde su representación intermedia a código máquina x86-64 sin enlazar contra `msvcrt.dll`, `ucrt.dll` ni `glibc`.
- **Punto fijo generacional reproducible (Self-Hosting):** Demostrada autorreconstrucción circular de 3 generaciones idéntica bit a bit tanto en Windows como en Linux (`Gen 2 SHA256 == Gen 3 SHA256`, con cero invocaciones a compiladores externos).
- **Baja latencia de compilación:** Los módulos estándar compilan nativamente en **30–55 ms** con un consumo reducido de memoria del compilador (~24.5 MiB).
- **Sintaxis canónica limpia (v2):** Gramática de sistemas diseñada específicamente para expresar intención: `flow`, `shape`, `choice`, `hold`, `change`, `during`, `when`, `give`.

---

## Inicio Rápido

### 1. Instalación

Instala ELE mediante los instaladores nativos sin dependencias externas:

- **En Windows:** Ejecuta `.\install.ps1` (instala en `$env:LOCALAPPDATA\ele\bin` y configura el PATH de usuario).
- **En Linux:** Ejecuta `./scripts/install.sh` (instala en `~/.ele/bin` y configura el PATH del shell).

Los paquetes de distribución independientes (`ele-windows-x86_64.zip` y `ele-linux-x86_64.tar.gz`) contienen el compilador autónomo sin requerir Rust, Cargo ni CRT.

### 2. Programa Mínimo (`hello.l`)

```ele
// hello.l: Punto de entrada estándar en sintaxis ELE v2
flow main() {
    print("¡Hola desde ELE nativo!")
}
```

### 3. Compilación con el Driver Autónomo

Una vez realizado el bootstrap inicial, ELE compila archivos fuente directamente a binarios ejecutables:

**En Windows:**
```powershell
.\bin\ele.exe build hello.l -o hello.exe
.\hello.exe
# Salida: ¡Hola desde ELE nativo!
```

**En Linux:**
```bash
./bin/ele.elf build hello.l --target elf -o hello
chmod +x hello
./hello
# Salida: ¡Hola desde ELE nativo!
```

Para instrucciones detalladas de compilación desde código fuente, consulta la [Guía de Inicio Rápido](docs/getting-started.md).

---

## Vista Rápida de la Sintaxis

```ele
// Declaraciones de estructuras y variantes
shape Vector2 {
    x: Int
    y: Int
}

choice Resultado {
    Exito(valor: Int)
    Fallo(codigo: Int)
}

// Funciones y flujo de control
flow calcular_magnitud(v: view Vector2) => Int {
    give v.x * v.x + v.y * v.y
}

flow main() => Int {
    // Vinculación de propietario inmutable
    hold pos = Vector2(x: 3, y: 4)

    // Préstamo compartido de pos mediante view
    hold mag = calcular_magnitud(pos)

    // Variable mutable
    change contador: Int = 0
    during contador < 3 {
        print("Iteración de magnitud: {mag}")
        contador = contador + 1
    }

    give 0
}
```

Consulta la [Referencia del Lenguaje](docs/language-reference.md) para especificaciones detalladas de tipos, colecciones (`List of[T]`) y el borrow checker.

---

## Rendimiento y Benchmarks

Todas las afirmaciones de rendimiento en ELE están respaldadas por benchmarks auditables y automatizados ejecutados sobre hardware real (Intel x86-64, Windows 10 y WSL2 Ubuntu). Ninguna cifra ni gráfico es simulado.

Para la metodología completa y los datos brutos, consulta el [Informe de Rendimiento](docs/performance.md) y la [Metodología de Benchmarking](docs/benchmarks/methodology.md).

**Procedencia de las mediciones:** Los resultados de Windows aquí mostrados se registraron en el commit [`56f34fb`](https://github.com/Joshua-EPR/ELE/commit/56f34fb437e20ca2b6b5613106f96ec153f36969) (20 de noviembre de 2026), **antes** de fusionar Stage 3.5. Son mediciones históricas, no resultados recién obtenidos de `main`. Se deben repetir los benchmarks sobre la versión integrada antes de atribuirle estas cifras. La comparativa externa y la suite de runtime independiente son experimentos diferentes; la tabla de runtime usa los datos de la comparativa.

### Latencia de Compilación

ELE compila programas pequeños y medianos en decenas de milisegundos:

<p align="center">
  <img src="assets/benchmarks/compilation-time.svg" alt="Latencia de Compilación" width="760">
</p>

| Carga de Trabajo | Líneas de Fuente | Mediana de Tiempo | Pico RSS (Memoria) | Tamaño de Salida |
|---|---|---|---|---|
| `hello.l` | 5 | **32.05 ms** | 1.18 MiB | 4,608 B |
| `arithmetic.l` | 10 | **32.90 ms** | 1.21 MiB | 5,120 B |
| `fibonacci.l` | 13 | **35.75 ms** | 1.21 MiB | 5,120 B |
| `text_processing.l` | 10 | **35.24 ms** | 1.20 MiB | 5,120 B |
| `multimodule (main.l)` | 10 | **33.36 ms** | 1.22 MiB | 5,120 B |
| `main_sema.l` (Compilador) | 278 | **3.16 s** | 52.46 MiB | 913,408 B |
| `main_driver.l` (Self-Host) | 692 | **5.23 s** | 87.53 MiB | 1,514,496 B |

---

### Consumo de Memoria durante la Compilación

El consumo de memoria del compilador es registrado de forma continua mediante APIs contables del kernel (Windows Job Objects `PeakProcessMemoryUsed` y Linux `getrusage`):

<p align="center">
  <img src="assets/benchmarks/peak-memory.svg" alt="Memoria Pico del Compilador" width="760">
</p>

---

### Rendimiento de Ejecución en Runtime

Evaluamos algoritmos idénticos entre **ELE**, **Rust (`rustc 1.99.1`)** y **C (`gcc 9.4.0`)** verificando salidas matemáticas exactas:

<p align="center">
  <img src="assets/benchmarks/runtime-performance.svg" alt="Rendimiento en Runtime" width="760">
</p>

| Benchmark | Lenguaje | Nivel de Optimización | Tiempo Compilación | Runtime (ms) | Tamaño Binario |
|---|---|---|---|---|---|
| **Fibonacci(25)** | **ELE** | `native-direct-emit` | 32.79 ms | 53.49 ms | 5,120 B |
| Fibonacci(25) | Rust | Debug (`-O0`) | 670.88 ms | 22.63 ms | 5,086,801 B |
| Fibonacci(25) | Rust | Release (`-O3`) | 716.37 ms | 24.92 ms | 5,085,050 B |
| **Loop(10M)** | **ELE** | `native-direct-emit` | 38.12 ms | 101.34 ms | 5,120 B |
| Loop(10M) | Rust | Debug (`-O0`) | 649.07 ms | 94.34 ms | 5,086,761 B |
| Loop(10M) | Rust | Release (`-O3`) | 690.35 ms | 21.47 ms | 5,084,972 B |

> [!NOTE]
> El backend nativo de ELE emite código máquina directamente desde bloques CFG, sin optimizaciones SSA. El rendimiento depende de la carga y la configuración; estas cifras describen experimentos concretos y no establecen una clasificación general entre lenguajes.

---

### Tamaño de los Binarios

Dado que los ejecutables generados por ELE no enlazan contra la biblioteca estándar de C ni empaquetan un runtime voluminoso, el tamaño del binario resultante es órdenes de magnitud menor:

<p align="center">
  <img src="assets/benchmarks/binary-size.svg" alt="Comparativa de Tamaño de Binarios" width="760">
</p>

---

## Autorreconstrucción y Reproducibilidad Generacional (Self-Hosting)

ELE ha establecido un ciclo de autorreconstrucción generacional determinista e idéntico bit a bit en Windows y Linux.

<p align="center">
  <img src="assets/benchmarks/self-hosting.svg" alt="Punto Fijo Generacional Self-Hosting" width="760">
</p>

- **Punto Fijo en Windows:** `Gen 2 SHA256 == Gen 3 SHA256` (`F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D`)
- **Punto Fijo en Linux:** `Gen 2 SHA256 == Gen 3 SHA256` (`4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9`)
- **Invocaciones Externas:** **0** (no se invoca a `rustc`, `cargo`, `gcc` ni `link.exe` durante las compilaciones de Gen 2 y Gen 3).

Para el informe arquitectónico completo, consulta la [Documentación de Self-Hosting](docs/self-hosting.md).

---

## Evolución de Auto-Cobertura (Self-Coverage)

<p align="center">
  <img src="assets/benchmarks/native-coverage.svg" alt="Evolución de Cobertura Nativa" width="760">
</p>

- **102 / 102 archivos fuente (100%)** en `compiler-l/src/` superan las fases de Lexer, Parser y Análisis Semántico.
- **20 / 102 archivos fuente (~19,6%)** alcanzan la fase de emisión del backend nativo; corresponden a los **20 / 20 puntos de entrada independientes** de la matriz actual. Esto no significa cobertura nativa total de las fuentes.

---

## Arquitectura del Compilador

El pipeline de compilación de ELE está estructurado en capas modulares de verificación:

```text
Fuente .l ──► Lexer ──► Parser ──► Sema y Tipos ──► Borrow Checker ──► ELE-LIR ──► CFG ──► Emisor x86-64 ──► PE32+ / ELF64
```

Consulta la [Arquitectura del Compilador](docs/architecture.md) para detalles sobre Pratt parsing, verificación de tipostate y codificación de instrucciones x86-64.

---

## Estado del Proyecto y Hoja de Ruta

ELE es un lenguaje de programación de sistemas en fase activa de investigación y desarrollo. Aunque el driver del compilador y los programas independientes son plenamente funcionales y autorreconstruibles, ELE no está recomendado todavía para entornos de producción de misión crítica.

Consulta las [Limitaciones Conocidas](docs/limitations.md) y la [Hoja de Ruta de Desarrollo](docs/roadmap.md) para detalles sobre funcionalidades planificadas, incluyendo soporte para ARM64, optimizador SSA con asignador de registros y concurrencia estructurada.

---

## Índice de Documentación

- [Guía de Inicio Rápido](docs/getting-started.md)
- [Especificación de Referencia del Lenguaje](docs/language-reference.md)
- [Arquitectura del Compilador](docs/architecture.md)
- [Autorreconstrucción y Punto Fijo Generacional](docs/self-hosting.md)
- [Informe de Rendimiento y Benchmarks](docs/performance.md)
- [Limitaciones Técnicas y de Seguridad](docs/limitations.md)
- [Hoja de Ruta de Desarrollo](docs/roadmap.md)
- [Metodología de Benchmarking](docs/benchmarks/methodology.md)
- [Guía de Reproducibilidad de Benchmarks](docs/benchmarks/reproducibility.md)

---

## Contribuciones y Licencia

Las contribuciones, informes de errores y sugerencias son bienvenidos. Por favor, asegúrate de que todos los cambios superen las puertas de calidad:

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test -p project-l --test ele_v2_legacy_ratchet
python benchmarks/scripts/validate_results.py
```

**Licencia:** No se ha publicado un archivo de licencia en la raíz del repositorio. No presupongas derechos de redistribución sin confirmar los términos del proyecto.
