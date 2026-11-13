//! NEXO-Core: IR tipada mínima del modelo de memoria NEXO v0.2.
//!
//! La IR es estructurada: los bloques son listas de sentencias y el flujo de
//! control se expresa con `Si`, `Repetir`, `Revalidar`, etc. Cada secuencia
//! maximal de sentencias simples entre sentencias compuestas forma un bloque
//! básico del CFG implícito. Cada variable tiene exactamente una sentencia que
//! la define y su ámbito va desde esa sentencia hasta el final del bloque que
//! la contiene (R1).

use std::fmt;

/// Variable local de una función (índice en [`Funcion::vars`]).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct VarId(pub u32);

/// Clase de objeto (índice en [`Programa::clases`]).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct ClaseId(pub u32);

/// Pool visible en una función (índice en [`Funcion::pools`]).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct PoolRef(pub u32);

/// Función del programa (índice en [`Programa::funciones`]).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct FuncId(pub u32);

/// Tipo de un campo de objeto. Los enlaces almacenados en un objeto apuntan
/// siempre al mismo pool que contiene el objeto: así el enlace queda atado por
/// propiedad a su pool (R4) y viaja con él en una transferencia (C2).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TipoCampo {
    Int,
    Enlace,
}

/// Declaración de clase. Solo las clases `enlazable` pueden vivir en pools
/// generacionales; el resto vive en la pila de datos por ámbitos (R2).
#[derive(Clone, Debug)]
pub struct Clase {
    pub nombre: String,
    pub enlazable: bool,
    pub campos: Vec<TipoCampo>,
}

/// Tamaño mínimo de slot: garantiza como mucho 64 slots por subpágina de
/// 4 KiB (un `u64` de bitmap) y 960 generaciones por superpágina.
pub const TAM_SLOT_MIN: u32 = 64;
/// Tamaño máximo de slot: un objeto de pool no puede cruzar subpáginas.
pub const TAM_SLOT_MAX: u32 = 4096;

impl Clase {
    /// Tamaño del slot en bytes: 8 bytes por campo, redondeado a múltiplo
    /// de 8 y como mínimo [`TAM_SLOT_MIN`].
    pub fn tam_slot(&self) -> u32 {
        let bruto = (self.campos.len() as u32).saturating_mul(8);
        bruto.max(TAM_SLOT_MIN)
    }

    pub fn tiene_enlaces(&self) -> bool {
        self.campos.contains(&TipoCampo::Enlace)
    }
}

/// Dónde vive un dueño.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Ubic {
    /// Pila de datos por ámbitos (estilo Goose, sin cabeceras).
    Pila,
    /// Pool generacional Bi-Slab.
    Pool(PoolRef),
}

/// Modo de un préstamo estático.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Modo {
    View,
    Edit,
}

/// Permiso con el que una función ve un pool.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub enum PermisoPool {
    View,
    Edit,
    /// Pool local de la función: lo crea al entrar y lo destruye al salir
    /// (o al transferirlo a otro hilo).
    Dueno,
}

/// Tipos de NEXO-Core.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Ty {
    Int,
    /// `dueño<T>`: lineal.
    Dueno(ClaseId, Ubic),
    /// `view<T>` / `edit<T>`: préstamos estáticos borrados en compilación.
    Prestamo(Modo, ClaseId, Ubic),
    /// `Enlace<P, T>`: 64 bits (`slot: u32`, `gen: u32`); la clase es la del pool.
    Enlace(PoolRef),
    /// `hueco<P, s>`: permiso lineal interno de ELE-LIR.
    Hueco(PoolRef),
    /// Época de destrucción validada de `P` (`contenedor.epoca_validada`).
    Sello(PoolRef),
    /// Valor función con firma conocida (llamadas indirectas).
    Funcion(Box<Firma>),
}

impl Ty {
    pub fn es_lineal(&self) -> bool {
        matches!(self, Ty::Dueno(..) | Ty::Hueco(_))
    }

    /// Pool al que está atado el valor, si lo hay.
    pub fn pool(&self) -> Option<PoolRef> {
        match self {
            Ty::Dueno(_, Ubic::Pool(p)) | Ty::Prestamo(_, _, Ubic::Pool(p)) => Some(*p),
            Ty::Enlace(p) | Ty::Hueco(p) | Ty::Sello(p) => Some(*p),
            _ => None,
        }
    }
}

/// Firma de una función usada como valor. Los `PoolRef` de `params` y `ret`
/// indexan `pools` de la propia firma.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Firma {
    pub pools: Vec<(ClaseId, PermisoPool)>,
    pub params: Vec<Ty>,
    pub ret: Option<Ty>,
    /// El valor función captura pools mutables del entorno.
    pub captura_mutable: bool,
    /// Efecto desconocido (FFI, código no analizado): se asume `destruye(todos)`.
    pub opaca: bool,
}

#[derive(Clone, Debug)]
pub struct PoolDecl {
    pub nombre: String,
    pub clase: ClaseId,
    pub permiso: PermisoPool,
}

#[derive(Clone, Debug)]
pub struct VarDecl {
    pub nombre: String,
    pub ty: Ty,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Operando {
    Var(VarId),
    Const(i64),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OpArit {
    Sumar,
    Restar,
    Menor,
    Igual,
}

/// Nivel de acceso de una revalidación, decidido por el verificador.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Nivel {
    /// Validez probada en compilación: no se lee `gen[s]`.
    Estatico,
    /// Validez probada dentro de un ámbito `congelar(P)`: sin leer `gen[s]`,
    /// compartible entre hilos.
    Congelado,
    /// Se lee `gen[s]` en ejecución.
    Comprobado,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Destino {
    Directa(FuncId),
    Indirecta(VarId),
}

pub type Bloque = Vec<Stmt>;

/// Sentencias de NEXO-Core.
#[derive(Clone, Debug)]
pub enum Stmt {
    Const {
        dst: VarId,
        valor: i64,
    },
    /// Copia de un valor copiable (`Int`, `view`, `Enlace`, `Sello`, función).
    Copiar {
        dst: VarId,
        src: VarId,
    },
    /// Movimiento de un dueño (consume `src`).
    Mover {
        dst: VarId,
        src: VarId,
    },
    Aritmetica {
        dst: VarId,
        op: OpArit,
        a: Operando,
        b: Operando,
    },
    /// Aloja un objeto: efecto `crece(P)` si vive en un pool.
    Crear {
        dst: VarId,
        clase: ClaseId,
        ubic: Ubic,
        campos: Vec<Operando>,
        /// Como en `Escribir`: el objeto guarda un enlace no probado.
        invalida_epoca: Option<bool>,
    },
    /// Destruye un dueño. En un pool se descompone en `gen[s] += 1` (par =
    /// muerto) y, si `hueco` es `Some`, produce `hueco<P, s>` en lugar de
    /// devolver el slot a la lista libre.
    Destruir {
        src: VarId,
        hueco: Option<VarId>,
        /// Insertado por el verificador al final de un ámbito.
        implicito: bool,
        /// *Drop flag*: solo destruye si `src` sigue vivo en ejecución.
        condicional: bool,
    },
    /// Consume `hueco<P, s>` y aloja in situ (`gen[s] += 1`, impar = vivo).
    ReusarHueco {
        dst: VarId,
        hueco: VarId,
        campos: Vec<Operando>,
        invalida_epoca: Option<bool>,
    },
    /// Devuelve a la lista libre un hueco no reutilizado.
    LiberarHueco {
        hueco: VarId,
    },
    /// Préstamo estático de un dueño o représtamo de un préstamo.
    Prestar {
        dst: VarId,
        src: VarId,
        modo: Modo,
    },
    Leer {
        dst: VarId,
        obj: VarId,
        campo: u32,
    },
    Escribir {
        obj: VarId,
        campo: u32,
        valor: Operando,
        /// `Some(true)` si el verificador no pudo probar válido el enlace
        /// almacenado: la escritura invalida la época del pool. `None` en IR
        /// sin verificar (se trata como `true`).
        invalida_epoca: Option<bool>,
    },
    Enlazar {
        dst: VarId,
        obj: VarId,
    },
    /// `revalidar enlace en cuerpo sino ausente`.
    Revalidar {
        enlace: VarId,
        modo: Modo,
        ligado: VarId,
        cuerpo: Bloque,
        ausente: Bloque,
        /// Las destrucciones de `P` dentro del cuerpo se encolan y se
        /// ejecutan al salir del bloque.
        diferir: bool,
        nivel: Option<Nivel>,
    },
    RevalidarLote {
        enlaces: Vec<VarId>,
        modo: Modo,
        ligados: Vec<VarId>,
        cuerpo: Bloque,
        ausente: Bloque,
        niveles: Vec<Option<Nivel>>,
    },
    /// Recorre `P` comprobando todos los enlaces almacenados; si todos son
    /// válidos produce `pool.epoca_destruccion`, si no un sello inválido.
    Sellar {
        dst: VarId,
        pool: PoolRef,
    },
    /// Si `pool.epoca_destruccion == sello`, los enlaces leídos de objetos
    /// de `P` dentro de `cuerpo` son válidos sin comprobar `gen[s]`.
    SiSellado {
        sello: VarId,
        cuerpo: Bloque,
        sino: Bloque,
    },
    /// Reestructuración interna (realojar buffer, cambiar variante):
    /// efecto `destruye(P)`.
    Reestructurar {
        pool: PoolRef,
    },
    Congelar {
        pool: PoolRef,
        cuerpo: Bloque,
    },
    /// Concurrencia estructurada: los hilos se unen al final.
    Paralelo {
        hilos: Vec<Bloque>,
    },
    /// `dividir(edit P, partes)`: `partes` trabajadores ejecutan `cuerpo` con
    /// `indice` = número de partición.
    Dividir {
        pool: PoolRef,
        partes: u32,
        indice: VarId,
        cuerpo: Bloque,
    },
    /// Transfiere un pool local a otro hilo que ejecuta `cuerpo` y lo destruye
    /// al terminar. Los dueños de `P` vivos se mueven con él.
    TransferirPool {
        pool: PoolRef,
        cuerpo: Bloque,
    },
    RefFuncion {
        dst: VarId,
        func: FuncId,
    },
    Llamar {
        destino: Destino,
        pools: Vec<PoolRef>,
        args: Vec<Operando>,
        dst: Option<VarId>,
    },
    Si {
        cond: Operando,
        entonces: Bloque,
        sino: Bloque,
    },
    Repetir {
        veces: Operando,
        indice: VarId,
        cuerpo: Bloque,
    },
    Retornar {
        valor: Option<Operando>,
    },
}

impl Stmt {
    /// Sentencia compuesta: termina el bloque básico en curso.
    pub fn es_compuesta(&self) -> bool {
        matches!(
            self,
            Stmt::Revalidar { .. }
                | Stmt::RevalidarLote { .. }
                | Stmt::SiSellado { .. }
                | Stmt::Congelar { .. }
                | Stmt::Paralelo { .. }
                | Stmt::Dividir { .. }
                | Stmt::TransferirPool { .. }
                | Stmt::Si { .. }
                | Stmt::Repetir { .. }
        )
    }

    /// Variables definidas directamente por la sentencia (no las de sus
    /// bloques anidados).
    pub fn defs(&self) -> Vec<VarId> {
        match self {
            Stmt::Const { dst, .. }
            | Stmt::Copiar { dst, .. }
            | Stmt::Mover { dst, .. }
            | Stmt::Aritmetica { dst, .. }
            | Stmt::Crear { dst, .. }
            | Stmt::ReusarHueco { dst, .. }
            | Stmt::Prestar { dst, .. }
            | Stmt::Leer { dst, .. }
            | Stmt::Enlazar { dst, .. }
            | Stmt::Sellar { dst, .. }
            | Stmt::RefFuncion { dst, .. } => vec![*dst],
            Stmt::Destruir { hueco, .. } => hueco.iter().copied().collect(),
            Stmt::Llamar { dst, .. } => dst.iter().copied().collect(),
            _ => Vec::new(),
        }
    }

    /// Variables usadas directamente por la sentencia (sin bloques anidados).
    pub fn usos(&self) -> Vec<VarId> {
        fn op(v: &mut Vec<VarId>, o: &Operando) {
            if let Operando::Var(x) = o {
                v.push(*x);
            }
        }
        let mut v = Vec::new();
        match self {
            Stmt::Const { .. } | Stmt::RefFuncion { .. } | Stmt::Sellar { .. } => {}
            Stmt::Copiar { src, .. } | Stmt::Mover { src, .. } => v.push(*src),
            Stmt::Aritmetica { a, b, .. } => {
                op(&mut v, a);
                op(&mut v, b);
            }
            Stmt::Crear { campos, .. } => campos.iter().for_each(|c| op(&mut v, c)),
            Stmt::Destruir { src, .. } => v.push(*src),
            Stmt::ReusarHueco { hueco, campos, .. } => {
                v.push(*hueco);
                campos.iter().for_each(|c| op(&mut v, c));
            }
            Stmt::LiberarHueco { hueco } => v.push(*hueco),
            Stmt::Prestar { src, .. } => v.push(*src),
            Stmt::Leer { obj, .. } => v.push(*obj),
            Stmt::Escribir { obj, valor, .. } => {
                v.push(*obj);
                op(&mut v, valor);
            }
            Stmt::Enlazar { obj, .. } => v.push(*obj),
            Stmt::Revalidar { enlace, .. } => v.push(*enlace),
            Stmt::RevalidarLote { enlaces, .. } => v.extend(enlaces.iter().copied()),
            Stmt::SiSellado { sello, .. } => v.push(*sello),
            Stmt::Reestructurar { .. }
            | Stmt::Congelar { .. }
            | Stmt::Paralelo { .. }
            | Stmt::Dividir { .. }
            | Stmt::TransferirPool { .. } => {}
            Stmt::Llamar { destino, args, .. } => {
                if let Destino::Indirecta(f) = destino {
                    v.push(*f);
                }
                args.iter().for_each(|a| op(&mut v, a));
            }
            Stmt::Si { cond, .. } => op(&mut v, cond),
            Stmt::Repetir { veces, .. } => op(&mut v, veces),
            Stmt::Retornar { valor } => {
                if let Some(o) = valor {
                    op(&mut v, o);
                }
            }
        }
        v
    }

    /// Bloques anidados, en orden.
    pub fn bloques(&self) -> Vec<&Bloque> {
        match self {
            Stmt::Revalidar {
                cuerpo, ausente, ..
            }
            | Stmt::RevalidarLote {
                cuerpo, ausente, ..
            } => {
                vec![cuerpo, ausente]
            }
            Stmt::SiSellado { cuerpo, sino, .. } => vec![cuerpo, sino],
            Stmt::Si { entonces, sino, .. } => vec![entonces, sino],
            Stmt::Congelar { cuerpo, .. }
            | Stmt::Dividir { cuerpo, .. }
            | Stmt::TransferirPool { cuerpo, .. }
            | Stmt::Repetir { cuerpo, .. } => vec![cuerpo],
            Stmt::Paralelo { hilos } => hilos.iter().collect(),
            _ => Vec::new(),
        }
    }

    pub fn nombre(&self) -> &'static str {
        match self {
            Stmt::Const { .. } => "const",
            Stmt::Copiar { .. } => "copiar",
            Stmt::Mover { .. } => "mover",
            Stmt::Aritmetica { .. } => "aritmetica",
            Stmt::Crear { .. } => "crear",
            Stmt::Destruir { .. } => "destruir",
            Stmt::ReusarHueco { .. } => "reusar_hueco",
            Stmt::LiberarHueco { .. } => "liberar_hueco",
            Stmt::Prestar { .. } => "prestar",
            Stmt::Leer { .. } => "leer",
            Stmt::Escribir { .. } => "escribir",
            Stmt::Enlazar { .. } => "enlazar",
            Stmt::Revalidar { .. } => "revalidar",
            Stmt::RevalidarLote { .. } => "revalidar_lote",
            Stmt::Sellar { .. } => "sellar",
            Stmt::SiSellado { .. } => "si_sellado",
            Stmt::Reestructurar { .. } => "reestructurar",
            Stmt::Congelar { .. } => "congelar",
            Stmt::Paralelo { .. } => "paralelo",
            Stmt::Dividir { .. } => "dividir",
            Stmt::TransferirPool { .. } => "transferir_pool",
            Stmt::RefFuncion { .. } => "ref_funcion",
            Stmt::Llamar { .. } => "llamar",
            Stmt::Si { .. } => "si",
            Stmt::Repetir { .. } => "repetir",
            Stmt::Retornar { .. } => "retornar",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Funcion {
    pub nombre: String,
    /// Los `n_pool_params` primeros son parámetros (permiso `View`/`Edit`);
    /// el resto son pools locales (permiso `Dueno`).
    pub pools: Vec<PoolDecl>,
    pub n_pool_params: usize,
    pub vars: Vec<VarDecl>,
    pub params: Vec<VarId>,
    pub ret: Option<Ty>,
    pub cuerpo: Bloque,
}

impl Funcion {
    pub fn ty(&self, v: VarId) -> &Ty {
        &self.vars[v.0 as usize].ty
    }

    pub fn nombre_var(&self, v: VarId) -> &str {
        &self.vars[v.0 as usize].nombre
    }

    pub fn nombre_pool(&self, p: PoolRef) -> &str {
        &self.pools[p.0 as usize].nombre
    }

    pub fn es_pool_param(&self, p: PoolRef) -> bool {
        (p.0 as usize) < self.n_pool_params
    }
}

#[derive(Clone, Debug, Default)]
pub struct Programa {
    pub clases: Vec<Clase>,
    pub funciones: Vec<Funcion>,
}

impl Programa {
    pub fn clase(&self, c: ClaseId) -> &Clase {
        &self.clases[c.0 as usize]
    }

    pub fn funcion(&self, f: FuncId) -> &Funcion {
        &self.funciones[f.0 as usize]
    }

    pub fn buscar(&self, nombre: &str) -> Option<FuncId> {
        self.funciones
            .iter()
            .position(|f| f.nombre == nombre)
            .map(|i| FuncId(i as u32))
    }

    pub fn clase_nueva(&mut self, nombre: &str, enlazable: bool, campos: &[TipoCampo]) -> ClaseId {
        self.clases.push(Clase {
            nombre: nombre.to_string(),
            enlazable,
            campos: campos.to_vec(),
        });
        ClaseId(self.clases.len() as u32 - 1)
    }

    pub fn agregar(&mut self, f: Funcion) -> FuncId {
        self.funciones.push(f);
        FuncId(self.funciones.len() as u32 - 1)
    }

    /// Reserva un índice de función para poder referirla antes de construirla
    /// (recursión, llamadas mutuas). Debe completarse con [`Programa::definir`].
    pub fn declarar(&mut self, nombre: &str) -> FuncId {
        self.agregar(Funcion {
            nombre: nombre.to_string(),
            pools: Vec::new(),
            n_pool_params: 0,
            vars: Vec::new(),
            params: Vec::new(),
            ret: None,
            cuerpo: Vec::new(),
        })
    }

    pub fn definir(&mut self, id: FuncId, f: Funcion) {
        self.funciones[id.0 as usize] = f;
    }
}

/// Constructor ergonómico de funciones.
pub struct Constructor {
    f: Funcion,
}

impl Constructor {
    pub fn nueva(nombre: &str) -> Self {
        Constructor {
            f: Funcion {
                nombre: nombre.to_string(),
                pools: Vec::new(),
                n_pool_params: 0,
                vars: Vec::new(),
                params: Vec::new(),
                ret: None,
                cuerpo: Vec::new(),
            },
        }
    }

    /// Declara un parámetro pool. Debe llamarse antes de cualquier pool local.
    pub fn pool_param(&mut self, nombre: &str, clase: ClaseId, permiso: PermisoPool) -> PoolRef {
        assert!(
            self.f.pools.len() == self.f.n_pool_params,
            "los pools parámetro deben declararse antes que los locales"
        );
        self.f.pools.push(PoolDecl {
            nombre: nombre.to_string(),
            clase,
            permiso,
        });
        self.f.n_pool_params += 1;
        PoolRef(self.f.pools.len() as u32 - 1)
    }

    pub fn pool_local(&mut self, nombre: &str, clase: ClaseId) -> PoolRef {
        self.f.pools.push(PoolDecl {
            nombre: nombre.to_string(),
            clase,
            permiso: PermisoPool::Dueno,
        });
        PoolRef(self.f.pools.len() as u32 - 1)
    }

    pub fn var(&mut self, nombre: &str, ty: Ty) -> VarId {
        self.f.vars.push(VarDecl {
            nombre: nombre.to_string(),
            ty,
        });
        VarId(self.f.vars.len() as u32 - 1)
    }

    pub fn param(&mut self, nombre: &str, ty: Ty) -> VarId {
        let v = self.var(nombre, ty);
        self.f.params.push(v);
        v
    }

    pub fn retorna(&mut self, ty: Ty) {
        self.f.ret = Some(ty);
    }

    pub fn cuerpo(mut self, cuerpo: Bloque) -> Funcion {
        self.f.cuerpo = cuerpo;
        self.f
    }
}

/// Atajos para construir sentencias en pruebas y en el fuzzer.
pub mod s {
    use super::*;

    pub fn constante(dst: VarId, valor: i64) -> Stmt {
        Stmt::Const { dst, valor }
    }
    pub fn copiar(dst: VarId, src: VarId) -> Stmt {
        Stmt::Copiar { dst, src }
    }
    pub fn mover(dst: VarId, src: VarId) -> Stmt {
        Stmt::Mover { dst, src }
    }
    pub fn crear(dst: VarId, clase: ClaseId, ubic: Ubic, campos: Vec<Operando>) -> Stmt {
        Stmt::Crear {
            dst,
            clase,
            ubic,
            campos,
            invalida_epoca: None,
        }
    }
    pub fn destruir(src: VarId) -> Stmt {
        Stmt::Destruir {
            src,
            hueco: None,
            implicito: false,
            condicional: false,
        }
    }
    pub fn destruir_en_hueco(src: VarId, hueco: VarId) -> Stmt {
        Stmt::Destruir {
            src,
            hueco: Some(hueco),
            implicito: false,
            condicional: false,
        }
    }
    pub fn reusar(dst: VarId, hueco: VarId, campos: Vec<Operando>) -> Stmt {
        Stmt::ReusarHueco {
            dst,
            hueco,
            campos,
            invalida_epoca: None,
        }
    }
    pub fn prestar(dst: VarId, src: VarId, modo: Modo) -> Stmt {
        Stmt::Prestar { dst, src, modo }
    }
    pub fn leer(dst: VarId, obj: VarId, campo: u32) -> Stmt {
        Stmt::Leer { dst, obj, campo }
    }
    pub fn escribir(obj: VarId, campo: u32, valor: Operando) -> Stmt {
        Stmt::Escribir {
            obj,
            campo,
            valor,
            invalida_epoca: None,
        }
    }
    pub fn enlazar(dst: VarId, obj: VarId) -> Stmt {
        Stmt::Enlazar { dst, obj }
    }
    pub fn revalidar(
        enlace: VarId,
        modo: Modo,
        ligado: VarId,
        cuerpo: Bloque,
        ausente: Bloque,
    ) -> Stmt {
        Stmt::Revalidar {
            enlace,
            modo,
            ligado,
            cuerpo,
            ausente,
            diferir: false,
            nivel: None,
        }
    }
    pub fn revalidar_diferido(
        enlace: VarId,
        modo: Modo,
        ligado: VarId,
        cuerpo: Bloque,
        ausente: Bloque,
    ) -> Stmt {
        Stmt::Revalidar {
            enlace,
            modo,
            ligado,
            cuerpo,
            ausente,
            diferir: true,
            nivel: None,
        }
    }
    pub fn lote(
        enlaces: Vec<VarId>,
        modo: Modo,
        ligados: Vec<VarId>,
        cuerpo: Bloque,
        ausente: Bloque,
    ) -> Stmt {
        let n = enlaces.len();
        Stmt::RevalidarLote {
            enlaces,
            modo,
            ligados,
            cuerpo,
            ausente,
            niveles: vec![None; n],
        }
    }
    pub fn llamar(f: FuncId, pools: Vec<PoolRef>, args: Vec<Operando>, dst: Option<VarId>) -> Stmt {
        Stmt::Llamar {
            destino: Destino::Directa(f),
            pools,
            args,
            dst,
        }
    }
    pub fn llamar_ind(
        f: VarId,
        pools: Vec<PoolRef>,
        args: Vec<Operando>,
        dst: Option<VarId>,
    ) -> Stmt {
        Stmt::Llamar {
            destino: Destino::Indirecta(f),
            pools,
            args,
            dst,
        }
    }
    pub fn si(cond: Operando, entonces: Bloque, sino: Bloque) -> Stmt {
        Stmt::Si {
            cond,
            entonces,
            sino,
        }
    }
    pub fn repetir(veces: Operando, indice: VarId, cuerpo: Bloque) -> Stmt {
        Stmt::Repetir {
            veces,
            indice,
            cuerpo,
        }
    }
    pub fn retornar(valor: Option<Operando>) -> Stmt {
        Stmt::Retornar { valor }
    }
    pub fn v(x: VarId) -> Operando {
        Operando::Var(x)
    }
    pub fn k(n: i64) -> Operando {
        Operando::Const(n)
    }
}

impl fmt::Display for Nivel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Nivel::Estatico => "estatico",
            Nivel::Congelado => "congelado",
            Nivel::Comprobado => "comprobado",
        })
    }
}
