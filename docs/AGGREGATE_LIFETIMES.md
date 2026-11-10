# Lifetimes estructurales de vistas locales

Un struct concreto puede declarar campos compartidos `&Int`, `&Bool`,
`&Float`, `&f32` o `&Text`. Cada campo guarda una dirección prestada con un
origen establecido al construir la vista. El tipo no es Copy. Los campos
propietarios conservan su semántica habitual.

El constructor de una vista inicializa directamente un binding `let`.
Un campo prestado exige `&lugar`, donde el lugar es una variable, un campo o
un elemento indexado. La lectura desreferencia el campo, como un parámetro
prestado. Un `let` puede mover una vista local a otro binding sin mover su
referente. La duración se infiere a partir de los usos de la vista y no
extiende el almacenamiento del propietario.

El CFG comprueba que cada puntero proviene del préstamo con el que se
inicializó ese campo, incluso después de un movimiento. Todos los
préstamos de una vista se mantienen durante cada uso de la vista. Los
drops destruyen sus campos propietarios y nunca liberan sus referentes.

El tipo se restringe a bindings locales. Sus campos prestados no se
reasignan y sus direcciones no se retornan ni se almacenan en otros
agregados. Las firmas, métodos de la vista y parámetros genéricos con
estos tipos quedan para contratos estructurales posteriores. Tampoco se
habilitan campos `&mut` en este incremento.


Los usos de cualquier campo o de un movimiento mantienen todos los préstamos
de esa vista. Esta aproximación coincide con el lifetime común del backend
Rust. Las proyecciones de los propietarios se conservan y permiten escribir
en campos disjuntos. Un índice dinámico puede coincidir con otro índice.

La forma futura `struct Vista<'a> { nombre: &'a Text }` es una propuesta
para contratos que atraviesen funciones o contenedores. Habilitarla exige
propagar las relaciones por campo durante retornos y movimientos.
