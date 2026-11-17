# ELE: sintaxis propia v2 — diseño y migración

> **Estado: implementación incremental, NO migración completa.** La extensión sigue siendo `.l`. El diseño de la sintaxis no cambia las reglas de seguridad, tipos, compilación, ownership, efectos ni el contrato ELE-LIR. Stage 0 se mantiene como bootstrap temporal; el objetivo sigue siendo un compilador, runtime y backend escritos íntegramente en ELE.

## Identidad

ELE **no** adopta la gramática de Rust como lenguaje público. Se conserva únicamente la notación genérica de programación donde no es distintiva ni perjudicial (operadores matemáticos, paréntesis para invocar, llaves para bloques, nombres de tipos). No se modifican símbolos arbitrariamente por estética si ello empeora legibilidad o seguridad. La nueva combinación de declaraciones, llamadas, control de flujo y préstamos es la identidad de ELE.

El dialecto antiguo queda admitido **temporalmente** por los parsers durante el bootstrap y para los ejemplos históricos; **no es una segunda sintaxis recomendada**. Un cambio futuro de versión desactivará los alias históricos en las fuentes de usuario, una vez que Stage 0, Stage 1, ejemplos, prelude, herramientas y CI hayan migrado. Un programa debe elegir una única convención.

## Superficie canónica

| Significado | Histórico (compatibilidad) | ELE v2 |
|---|---|---|
| Función | `fn` | `flow` |
| Estructura nominal | `struct` | `shape` |
| Métodos de un tipo | `impl` | `extend` |
| Enumeración algebraica | `enum` | `choice` |
| Contrato de métodos | `trait` | `contract` |
| Visibilidad exportada | `pub` | `expose` |
| Variable inmutable | `let` | `hold` |
| Variable mutable | `var` | `change` |
| Constante | `const` | `fixed` |
| Retorno explícito | `return` | `give` |
| Anotación de retorno | `-> Tipo` | `=> Tipo` |
| Llamada a método / asociado | `valor.metodo(x)` / `Tipo.metodo()` | `valor@metodo(x)` / `Tipo@metodo()` |
| Campo de un valor | `obj.campo` | `obj.campo` (**no** se confunde con un método) |
| Ramas exhaustivas | `match` | `choose` |
| Separador de brazo | `patrón => cuerpo` | `patrón: cuerpo` |
| Condición | `if` / `else` | `when` / `otherwise` |
| Iteración | `for ... in` | `each ... among` |
| Bucle condicionado | `while` | `during` |
| Bucle indefinido | `loop` | `repeat` |
| Salir / continuar bucle | `break` / `continue` | `leave` / `proceed` |
| Referencia implícita al receptor | `self` | `this` |
| Receptor mutable exclusivo | `mut flow` | `exclusive flow` |
| Método asociado | `static fn` | `direct flow` |
| Importación | `import` | `take` |
| Módulo | `module` | `space` |
| Región | `region` | `zone` |
| Función asíncrona | `async fn` | `later flow` |
| Suspender / iniciar tarea | `await` / `spawn` | `wait` / `launch` |
| Préstamo compartido | `&T` / `&valor` | `view T` / `view valor` |
| Préstamo exclusivo | `&mut T` / `&mut valor` | `edit T` / `edit valor` |

Los imports conservan la forma de módulo con puntos (`take src.math.rng`).
También pueden expresarse como rutas de archivo relativas entre carpetas:
`take "../src/math/rng"`. Las rutas se resuelven desde el archivo importador,
aceptan `..` dentro del árbol del proyecto y no pueden escapar de él; la
extensión `.l` se agrega cuando se omite.

**Estado real por frontend:**
- **Stage 0 (Rust/bootstrap):** implementadas las palabras clave v2, `=>`, `@metodo(...)`, `choose` con separador `:`, y `view`/`edit` para tipos/expresiones, reutilizando las mismas comprobaciones semánticas. Se admiten alias anteriores para la migración.
- **Stage 1 (escrito en ELE):** implementado el reconocimiento de las palabras v2 allí donde **ya existen** las construcciones correspondientes; `=>`, `@metodo(...)`, `choose` con `:`. Los métodos/contratos genéricos y las expresiones `view`/`edit` aún no están integrados de extremo a extremo en Stage 1; **no se debe afirmar soporte Stage 1 por leer esta tabla**.
- **Ejecutable nativo:** verificar la ruta del ejemplo `examples/ele_original_syntax.l`: `.l` → Stage 1 → ELE-LIR → backend ELE → ELF64 en CI Windows/Linux. La aceptación depende de la ejecución real, no de la presencia del fixture.

## Ejemplos

### Funciones, datos y métodos (Stage 0)

```ele
expose shape Cuenta {
    saldo: Int
}

extend Cuenta {
    exclusive flow ingresar(monto: Int) => Int {
        this.saldo += monto
        give this.saldo
    }

    direct flow nueva() => Self {
        give Cuenta(saldo: 0)
    }
}

flow main() => Int {
    change cuenta = Cuenta@nueva()
    hold resultado = cuenta@ingresar(42)
    give resultado
}
```

### Decisiones por variante (Stage 0 y Stage 1, subconjunto primitivo)

```ele
choice Estado {
    No,
    Si(Int),
}

flow main() => Int {
    hold estado = Estado.Si(42)
    choose estado {
        Estado.No: { give 0 },
        Estado.Si(valor): { give valor },
    }
    give 1
}
```

### Préstamos (Stage 0; migración Stage 1 pendiente)

```ele
flow leer(valor: view Int) => Int {
    give 42
}

flow main() => Int {
    hold dato = 5
    give leer(view dato)
}
```

`view` y `edit` son modos de préstamo, **no** claves para ignorar restricciones de aliasing/vida útil. `edit` conserva exclusividad y `view` solo permite lectura.

## Genéricos propios de ELE: `of[T]` (Stage 0)

En la sintaxis recomendada, **la declaración de parámetros de tipo y su aplicación usan `of[...]`**: no tienen la doble interpretación de los símbolos `<`/`>` como operadores de comparación. En contexto de expresiones, un genérico explícito debe terminar en una llamada con paréntesis; `id of[Int]` sin `(...)` **no** se trata como acceso a un array.

```ele
flow identidad of[T](valor: T) => T = valor

shape Caja of[T] {
    dato: T
}

extend of[T] Caja of[T] {
    flow leer() => T = this.dato
}

contract Lectura {
    flow codigo() => Int
}

shape Mensaje { numero: Int }

extend Lectura on Mensaje {
    flow codigo() => Int = this.numero
}

flow main() => Int {
    hold n = identidad of[Int](42)
    hold c: Caja of[Int] = Caja(dato: n)
    give c@leer()
}
```

Los `<T>` y `Tipo<T>` previos siguen admitidos **solo durante la migración**. La identidad de los tipos no depende de la forma escrita: `Caja<Int>` y `Caja of[Int]` producen el mismo tipo interno y pasan por el mismo control de ownership, reglas de monomorfización y verificación de tipos.

**Compatibilidad real:** Stage 0 implementa `of[T]` en declaraciones, tipos, llamadas y extensiones genéricas y contrasta sus dos backends. Stage 1 **solo** reconoce `Type of[Args]` como anotación de tipo para los genéricos integrados `List`, `Option` y `Result`; conserva el mismo AST y resolución de tipos que `Type<Args>`. No admite funciones o tipos genéricos definidos por el usuario, ni `funcion of[Int](...)` en Stage 1. La prueba diferencial Stage 0 contrasta Rustc y Cranelift, **no** demuestra self-hosting.

### Subconjunto comprobable de Stage 1

```ele
flow count(items: List of[Int]) => Int {
    give items.length
}

flow main() => Int {
    give 42
}
```

Se comprueban también las anotaciones `Option of[Int]`, `Result of[Int, Text]` y el anidamiento `List of[Option of[Int]]` mediante el compilador Stage 1 generado por Stage 0. La corrección se comprueba por aceptación de tipos y rechazo de genéricos con aridad errónea; esto **no** significa que el backend nativo de ELE soporte todavía los valores propietarios de todos estos tipos.

## Superficies por rediseñar antes del corte de compatibilidad

Estas son **propuestas de diseño, NO sintaxis soportada actualmente**; están sujetas a pruebas y decisiones técnicas, sin alterar la semántica estable:

1. **Genéricos (Stage 0 implementado):** `flow identidad of[T](x: T) => T`, `shape Caja of[T]`, `choice Estado of[T]`, `extend of[T] Caja of[T]`, `Caja of[Int]`, `identidad of[Int](42)` y `objeto@metodo of[Int](...)`. Esta sintaxis se distingue de índices y comparaciones gracias al marcador `of`. La monomorfización continúa utilizando el AST y la semántica existentes. **Pendiente:** parser/semántica de genéricos en Stage 1 y migración de fuentes históricas.
2. **Constructores:** establecer una forma propia que distinga creación de datos de llamadas a funciones y conserve nombres de campos/orden de evaluación, sin cambiar arbitrariamente el AST.
3. **Nombres del prelude y propagación:** decidir `Maybe` / `Outcome` en lugar de `Option` / `Result`, y una propagación explícita que no copie literalmente el postfix `?` de Rust. Antes de cambiar, garantizar drops y las pruebas de #5/#6.
4. **Patrones, guards y errores:** completar `choose` anidado, exhaustividad, errores y bindings con seguridad de ownership; syntax v2 no puede aceptar funcionalidades que el backend no soporta.
5. **Metaprogramación, traits y async:** terminar la migración de `contract`, `later flow`, efectos y visibilidad; preservar reglas de tipos y compatibilidad del protocolo.
6. **Parser completamente propio:** retirar los nombres de tokens históricos del frontend tras migración, manteniendo los orígenes de spans/diagnósticos, bibliotecas, ejemplos y herramientas.
7. **Formateador, resaltado, LSP, documentación y pruebas:** expresar exclusivamente ELE v2 de cara a nuevos usuarios; bloquear nuevas introducciones de la sintaxis histórica con un linter de CI una vez completada la migración.

## Estrategia segura y criterios

1. Introducir gramática y tests de equivalencia sintáctica **sin** transformar bytes de strings o comentarios (no usar regex globales sobre fuentes).
2. Compilar nuevos ejemplos con Stage 0 y Stage 1, verificar los mismos tipos/errores/ownership, LIR y resultados observables.
3. Mantener la rama original de CI y los tests históricos hasta reemplazar sus fuentes sin regresiones; después activar diagnostics de deprecación y finalmente retirar los alias.
4. Nunca editar LIR, ELF/PE ni cambiar ABI solo para reflejar cambios de nombre. Un cambio léxico no valida un nuevo soporte de runtime, Option/Result o Stage 2.
5. No declarar **lenguaje completamente migrado** hasta que el código fuente del compilador ELE, prelude, ejemplos, tests y herramientas utilice exclusivamente la gramática canónica y pase las comprobaciones reales.

**Alcance actual:** fase 1 de una migración semánticamente conservadora; todavía no se puede declarar que *todas* las similitudes con Rust estén eliminadas del repositorio o del compilador.
