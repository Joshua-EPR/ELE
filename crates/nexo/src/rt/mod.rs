//! Máquina abstracta ejecutable con oráculo (Etapa 2).

pub mod maquina;
pub mod metricas;
pub mod oraculo;
pub mod pool;

pub use maquina::{Config, Maquina, RefObj, Valor, ejecutar};
pub use metricas::Metricas;
pub use oraculo::{Aborto, Violacion};
