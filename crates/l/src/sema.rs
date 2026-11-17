//! Name resolution, static type checking and lowering to the independent LIR.
use crate::lir::{INVALID_SLEEP, MAX_SLEEP_MS, PlatformOp, SLEEP_MS};
use crate::{
    Diagnostic, Span,
    effects::{Attribute, EffectSet, FnContract, TraitMethodContract},
    exhaustive::{self, Issue},
    parser::{self, ExprKind, FnKind, PatternKind, Stmt, Type, TypeExpr},
};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};

use crate::lir::{
    Arm, EnumDef, Function, Instruction, Pattern, Place, Program, Receiver, StructDef, Value,
    ValueKind,
};

/// Diagnostic code used while a callee's inferred result type is not known yet.
/// The driver retries such functions; if no progress is possible the code is
/// reported as a real diagnostic (inference cycle).
const INFER_CODE: &str = "L0006";

/// Source of the prelude (Option, Result), parsed before every program.
const PRELUDE: &str = include_str!("prelude.l");

/// Maximum nesting of generic enum instantiations (`Option<Option<...>>`).
const MAX_INSTANTIATION_DEPTH: usize = 32;

fn get_noalloc(attrs: &[Attribute]) -> Option<Span> {
    attrs.iter().map(|Attribute::NoAlloc(sp)| *sp).next()
}

#[derive(Clone)]
struct Binding {
    id: usize,
    ty: Type,
    mutable: bool,
    constant: Option<Value>,
    ref_mode: Option<Receiver>,
    scope: usize,
}

struct Sig {
    borrow_return: Option<crate::lir::BorrowReturn>,
    view_return: Option<crate::lir::ViewReturn>,
    name: String,
    /// `async fn`: `result` is its future type and `async_result` what the
    /// body returns.
    is_async: bool,
    async_result: Option<Type>,
    kind: FnKind,
    owner: Option<Type>,
    params: Vec<Type>,
    param_modes: Vec<Option<Receiver>>,
    /// `None` while the result of an unannotated function is still unknown.
    result: Option<Type>,
}

fn aggregate_escape(span: Span) -> Diagnostic {
    err(span, "escape hacia un agregado: las referencias no se pueden almacenar en campos, variantes ni colecciones sin un contrato de vida del agregado")
        .classify("L0014", "préstamos")
}

fn view_escape(span: Span) -> Diagnostic {
    err(span, "una vista con campos prestados solo puede construirse o moverse a un let local; no puede cruzar una firma ni almacenarse en otro agregado")
        .classify("L0014", "préstamos")
}
fn lifetime(span: Span, message: impl Into<String>) -> Diagnostic {
    err(span, message).classify("L0013", "préstamos")
}

struct StructInfo {
    local_view: bool,
    name: String,
    fields: Vec<(String, Type)>,
    defaults: Vec<Option<Value>>,
}

/// Enum declaration as written; generic enums are instantiated on demand.
struct EnumTemplate {
    name: String,
    params: Vec<String>,
    variants: Vec<(String, Vec<TypeExpr>)>,
    /// Declared in the prelude: variants are usable without qualification.
    prelude: bool,
}

struct EnumInfo {
    local_view: bool,
    def: EnumDef,
    template: usize,
    args: Vec<Type>,
}

#[allow(dead_code)]
struct StructTemplate {
    name: String,
    params: Vec<parser::TypeParam>,
    fields: Vec<parser::Field>,
    span: Span,
}

#[allow(dead_code)]
struct FnTemplate {
    func: parser::Function,
    owner: Option<Type>,
}

#[allow(dead_code)]
struct TraitInfo {
    name: String,
    params: Vec<parser::TypeParam>,
    methods: Vec<parser::Function>,
    span: Span,
}

#[allow(dead_code)]
struct GenericTraitImpl {
    params: Vec<parser::TypeParam>,
    trait_id: usize,
    target_template: usize,
    methods: Vec<parser::Function>,
    span: Span,
}

#[allow(dead_code)]
struct MethodTemplate {
    params: Vec<parser::TypeParam>,
    target_template: usize,
    func: parser::Function,
    span: Span,
}

#[derive(Clone)]
enum FnTarget {
    Ast(parser::Function),
    /// The built-in `yieldNow`: its body is a single suspension point.
    YieldNow,
    Sleep,
    Specialized {
        template_id: usize,
        bindings: Vec<(String, Type)>,
    },
    SpecializedMethod {
        func: parser::Function,
        bindings: Vec<(String, Type)>,
    },
}

#[derive(Clone)]
struct FnToCompile {
    id: usize,
    target: FnTarget,
}

/// Module-level declarations shared by every function checker.
struct Env {
    structs: RefCell<Vec<StructInfo>>,
    join_pairs: RefCell<HashMap<[Type; 2], usize>>,
    struct_ids: HashMap<String, usize>,
    struct_templates: Vec<StructTemplate>,
    struct_template_ids: HashMap<String, usize>,
    struct_instances: RefCell<HashMap<(usize, Vec<Type>), usize>>,
    struct_args: RefCell<HashMap<usize, Vec<Type>>>,
    struct_template_of: RefCell<HashMap<usize, usize>>,
    instantiating_structs: RefCell<Vec<(usize, Vec<Type>)>>,

    templates: Vec<EnumTemplate>,
    template_ids: HashMap<String, usize>,
    /// Concrete enums (monomorphized instances), grown while checking bodies.
    enums: RefCell<Vec<EnumInfo>>,
    enum_ids: RefCell<HashMap<(usize, Vec<Type>), usize>>,
    instantiating: RefCell<Vec<(usize, Vec<Type>)>>,
    /// Unqualified variant names (prelude): name → (template, variant index).
    unqualified: HashMap<String, (usize, usize)>,
    /// Source name of every lexical region, indexed by region id.
    regions: RefCell<Vec<String>>,
    /// Interned collection types (indices are `Type::Array/Slice/List` ids).
    arrays: RefCell<Vec<crate::lir::ArrayDef>>,
    slices: RefCell<Vec<Type>>,
    lists: RefCell<Vec<Type>>,
    task_groups: RefCell<Vec<crate::lir::TaskGroupDef>>,
    task_group_ids: RefCell<HashMap<(Type, usize), usize>>,
    next_scope_id: Cell<usize>,
    scope_parents: RefCell<HashMap<usize, usize>>,
    /// Future type of each async function (see `lir::FutureDef`).
    futures: RefCell<Vec<crate::lir::FutureDef>>,

    traits: Vec<TraitInfo>,
    trait_ids: HashMap<String, usize>,
    trait_impls: RefCell<HashMap<(usize, Type), usize>>,
    generic_trait_impls: Vec<GenericTraitImpl>,

    functions: RefCell<HashMap<String, usize>>,
    /// Every declared free function, identified by source file and name.
    module_functions: RefCell<HashMap<(u32, String), usize>>,
    /// Imported file IDs keyed by the importing source file (one edge per take/import).
    direct_imports: HashMap<u32, HashSet<u32>>,
    /// IDs of exported free functions (which win unqualified lookup).
    public_functions: RefCell<HashSet<usize>>,
    /// Names with multiple private definitions and no unique unqualified binding.
    ambiguous_private_functions: RefCell<HashSet<String>>,
    methods: RefCell<HashMap<(Type, String), usize>>,
    sigs: RefCell<Vec<Sig>>,

    fn_templates: Vec<FnTemplate>,
    fn_template_ids: HashMap<String, usize>,
    /// Generic functions retain their defining module, as non-generic flows do.
    module_fn_templates: HashMap<(u32, String), usize>,
    public_fn_templates: HashSet<usize>,
    ambiguous_private_fn_templates: HashSet<String>,
    fn_instances: RefCell<HashMap<(usize, Vec<Type>), usize>>,
    instantiating_fns: RefCell<Vec<(usize, Vec<Type>)>>,

    method_templates: Vec<MethodTemplate>,
    queued_fns: RefCell<Vec<FnToCompile>>,

    fn_contracts: RefCell<HashMap<usize, FnContract>>,
    trait_contracts: Vec<TraitMethodContract>,
    impl_methods: RefCell<HashMap<(String, String), Vec<usize>>>,
}

impl exhaustive::Variants for Env {
    fn payloads(&self, enum_id: usize) -> Vec<Vec<Type>> {
        self.enums.borrow()[enum_id]
            .def
            .variants
            .iter()
            .map(|(_, p)| p.clone())
            .collect()
    }
    fn variant_name(&self, enum_id: usize, variant: usize) -> String {
        let enums = self.enums.borrow();
        let info = &enums[enum_id];
        let template = &self.templates[info.template];
        let name = &info.def.variants[variant].0;
        if template.prelude {
            name.clone()
        } else {
            format!("{}.{name}", template.name)
        }
    }
}

fn err(span: Span, message: impl Into<String>) -> Diagnostic {
    Diagnostic::new(span, message)
}

type BorrowSigResult = (
    Option<Type>,
    Option<crate::lir::BorrowReturn>,
    Option<crate::lir::ViewReturn>,
);

impl Env {
    /// Module-local declarations win. For modular sources, only explicitly
    /// imported public functions are considered; transitive/sibling modules
    /// cannot leak through the legacy global lookup table.
    /// Source file 0 remains the standalone (non-modular) compilation path.
    fn free_function(
        &self,
        name: &str,
        source_file: u32,
        span: Span,
    ) -> Result<Option<usize>, Diagnostic> {
        if let Some(id) = self
            .module_functions
            .borrow()
            .get(&(source_file, name.to_owned()))
            .copied()
        {
            return Ok(Some(id));
        }
        if source_file == 0 {
            return Ok(self.functions.borrow().get(name).copied());
        }
        let Some(imports) = self.direct_imports.get(&source_file) else {
            return Ok(None);
        };
        let definitions = self.module_functions.borrow();
        let exported = self.public_functions.borrow();
        let mut found = None;
        let key = name.to_owned();
        for &file in imports {
            if let Some(&id) = definitions.get(&(file, key.clone()))
                && exported.contains(&id)
                && found.replace(id).is_some()
            {
                return Err(
                    err(span, format!("función ambigua: {name}")).classify("L0014", "módulos")
                );
            }
        }
        Ok(found)
    }

    /// Generic templates follow exactly the same local/direct-import rules.
    fn free_template(
        &self,
        name: &str,
        source_file: u32,
        span: Span,
    ) -> Result<Option<usize>, Diagnostic> {
        if let Some(id) = self
            .module_fn_templates
            .get(&(source_file, name.to_owned()))
            .copied()
        {
            return Ok(Some(id));
        }
        if source_file == 0 {
            return Ok(self.fn_template_ids.get(name).copied());
        }
        let Some(imports) = self.direct_imports.get(&source_file) else {
            return Ok(None);
        };
        let mut found = None;
        let key = name.to_owned();
        for &file in imports {
            if let Some(&id) = self.module_fn_templates.get(&(file, key.clone()))
                && self.public_fn_templates.contains(&id)
                && found.replace(id).is_some()
            {
                return Err(err(span, format!("función genérica ambigua: {name}"))
                    .classify("L0014", "módulos"));
            }
        }
        Ok(found)
    }

    fn region_name(&self, r: usize) -> String {
        if r == crate::lir::CALLER_REGION {
            "del llamador".into()
        } else {
            format!("'{}'", self.regions.borrow()[r])
        }
    }
    /// Rejects region-bound types where a value could outlive its region.
    fn is_view(&self, ty: Type) -> bool {
        match ty {
            Type::Struct(id) => self.structs.borrow().get(id).is_some_and(|s| s.local_view),
            Type::Enum(id) => self.enums.borrow().get(id).is_some_and(|e| e.local_view),
            Type::Array(id) => {
                let elem = self.arrays.borrow()[id].elem;
                matches!(elem, Type::SharedField(_) | Type::MutField(_)) || self.is_view(elem)
            }
            Type::List(elem) => {
                let elem_ty = self.lists.borrow()[elem];
                matches!(elem_ty, Type::SharedField(_) | Type::MutField(_)) || self.is_view(elem_ty)
            }
            _ => false,
        }
    }
    fn async_owned(&self, ty: Type) -> bool {
        let structs = self.structs.borrow();
        let enums = self.enums.borrow();
        ty.async_owned(
            &|id| &structs[id].fields,
            &|id| &enums[id].def.variants,
            &self.arrays.borrow(),
            &self.lists.borrow(),
            &self.task_groups.borrow(),
        )
    }

    fn not_region_bound(&self, t: Type, what: &str, span: Span) -> Result<(), Diagnostic> {
        if matches!(t, Type::Struct(id) if self.structs.borrow().get(id).is_some_and(|s| s.local_view))
        {
            return Err(view_escape(span));
        }
        match t {
            Type::RegionList(_, r) => Err(err(
                span,
                format!("la lista pertenece a la región {} y no puede {what}", self.region_name(r)),
            ).classify("L0011", "regiones")),
            Type::Bytes(r) => Err(err(
                span,
                format!(
                    "el buffer pertenece a la región {} y no puede {what}: su memoria se libera al terminar la región",
                    self.region_name(r)
                ),
            )
            .classify("L0011", "regiones")),
            Type::Region(r) => Err(err(
                span,
                format!("la región {} no puede {what}", self.region_name(r)),
            )
            .classify("L0011", "regiones")),
            _ => Ok(()),
        }
    }
    fn array_ty(&self, elem: Type, len: usize, span: Span) -> Result<Type, Diagnostic> {
        if matches!(elem, Type::Future(_)) {
            return Err(err(
                span,
                "Future no se puede almacenar en un agregado ni colecciones",
            )
            .classify("L0015", "concurrencia"));
        }
        self.not_region_bound(elem, "guardarse en un array", span)?;
        let def = crate::lir::ArrayDef { elem, len };
        let mut arrays = self.arrays.borrow_mut();
        Ok(Type::Array(match arrays.iter().position(|a| *a == def) {
            Some(i) => i,
            None => {
                arrays.push(def);
                arrays.len() - 1
            }
        }))
    }
    fn slice_ty(&self, elem: Type, span: Span) -> Result<Type, Diagnostic> {
        if matches!(elem, Type::Future(_)) {
            return Err(err(
                span,
                "Future no se puede almacenar en un agregado ni colecciones",
            )
            .classify("L0015", "concurrencia"));
        }
        self.not_region_bound(elem, "guardarse en un slice", span)?;
        let mut slices = self.slices.borrow_mut();
        Ok(Type::Slice(match slices.iter().position(|e| *e == elem) {
            Some(i) => i,
            None => {
                slices.push(elem);
                slices.len() - 1
            }
        }))
    }
    fn list_ty(&self, elem: Type, span: Span) -> Result<Type, Diagnostic> {
        if matches!(elem, Type::Future(_)) {
            return Err(err(
                span,
                "Future no se puede almacenar en un agregado ni colecciones",
            )
            .classify("L0015", "concurrencia"));
        }
        self.not_region_bound(elem, "guardarse en una lista", span)?;
        // A group is homogeneous by result, independent of the function
        // that created each handle. The first future with that result supplies
        // the canonical result layout for this list type.
        let elem = if let Type::Task(task) = elem {
            let futures = self.futures.borrow();
            let result = futures[task].result;
            Type::Task(
                futures
                    .iter()
                    .position(|f| f.result == result)
                    .unwrap_or(task),
            )
        } else {
            elem
        };
        let mut lists = self.lists.borrow_mut();
        Ok(Type::List(match lists.iter().position(|e| *e == elem) {
            Some(i) => i,
            None => {
                lists.push(elem);
                lists.len() - 1
            }
        }))
    }
    fn same_list_element(
        &self,
        expected: Type,
        actual: Type,
        span: Span,
    ) -> Result<(), Diagnostic> {
        if let (Type::Task(a), Type::Task(b)) = (expected, actual) {
            let futures = self.futures.borrow();
            if futures[a].result == futures[b].result {
                return Ok(());
            }
        }
        self.same(expected, actual, span)
    }

    fn group_task(&self, ty: Type) -> Option<usize> {
        match ty {
            Type::List(id) => match self.lists.borrow()[id] {
                Type::Task(task) => Some(task),
                _ => None,
            },
            _ => None,
        }
    }

    /// Element type of an array, slice or list.
    fn elem_of(&self, t: Type) -> Option<Type> {
        match t {
            Type::Array(a) => Some(self.arrays.borrow()[a].elem),
            Type::Slice(s) => Some(self.slices.borrow()[s]),
            Type::List(l) | Type::RegionList(l, _) => Some(self.lists.borrow()[l]),
            _ => None,
        }
    }
    fn join_pair(&self, results: [Type; 2]) -> Type {
        if let Some(&id) = self.join_pairs.borrow().get(&results) {
            return Type::Struct(id);
        }
        let name = format!(
            "JoinPair<{}, {}>",
            self.type_name(results[0]),
            self.type_name(results[1])
        );
        let mut structs = self.structs.borrow_mut();
        let id = structs.len();
        structs.push(StructInfo {
            local_view: false,
            name,
            fields: vec![("first".into(), results[0]), ("second".into(), results[1])],
            defaults: vec![None; 2],
        });
        self.join_pairs.borrow_mut().insert(results, id);
        Type::Struct(id)
    }

    fn next_scope(&self, parent: usize) -> usize {
        let id = self.next_scope_id.get();
        self.next_scope_id.set(id + 1);
        self.scope_parents.borrow_mut().insert(id, parent);
        id
    }

    fn is_subscope_of(&self, inner: usize, outer: usize) -> bool {
        if inner == outer {
            return true;
        }
        let parents = self.scope_parents.borrow();
        let mut curr = inner;
        while let Some(&p) = parents.get(&curr) {
            if p == outer {
                return true;
            }
            if p == curr || p == 0 {
                break;
            }
            curr = p;
        }
        false
    }

    fn task_group_ty(&self, elem: Type, scope: usize, span: Span) -> Result<Type, Diagnostic> {
        self.not_region_bound(elem, "TaskGroup", span)?;
        let mut map = self.task_group_ids.borrow_mut();
        if let Some(&id) = map.get(&(elem, scope)) {
            return Ok(Type::TaskGroup(id));
        }
        let mut groups = self.task_groups.borrow_mut();
        let id = groups.len();
        groups.push(crate::lir::TaskGroupDef { elem, scope });
        map.insert((elem, scope), id);
        Ok(Type::TaskGroup(id))
    }

    fn type_name(&self, t: Type) -> String {
        match t {
            Type::Array(a) => {
                let def = self.arrays.borrow()[a];
                format!("[{}; {}]", self.type_name(def.elem), def.len)
            }
            Type::Slice(e) => format!("[{}]", self.type_name(self.slices.borrow()[e])),
            Type::List(e) => format!("List<{}>", self.type_name(self.lists.borrow()[e])),
            Type::RegionList(e, r) => format!(
                "List<{}> (región {})",
                self.type_name(self.lists.borrow()[e]),
                self.region_name(r)
            ),
            Type::TaskGroup(g) => {
                let elem = self.task_groups.borrow()[g].elem;
                format!("TaskGroup<{}>", self.type_name(elem))
            }
            Type::Future(f) => {
                let def = &self.futures.borrow()[f];
                if def.func == usize::MAX {
                    format!("Future<{}>", self.type_name(def.result))
                } else {
                    def.name.clone()
                }
            }
            Type::Task(f) => {
                let def = &self.futures.borrow()[f];
                format!("TaskHandle<{}> (de {})", self.type_name(def.result), {
                    let n = &def.name;
                    n[n.find("(de ").map(|i| i + 4).unwrap_or(0)..].trim_end_matches(')')
                })
            }
            Type::Bytes(r) => format!("Bytes (región {})", self.region_name(r)),
            Type::Region(r) => format!("región {}", self.region_name(r)),
            Type::Struct(id) => self.structs.borrow()[id].name.clone(),
            Type::Enum(id) => self.enums.borrow()[id].def.name.clone(),
            Type::Unit => "()".into(),
            Type::F32 => "f32".into(),
            other => format!("{other:?}"),
        }
    }
    /// The future type of async function `func` returning `result`.
    fn future_ty(&self, result: Type, func: usize, fname: &str) -> Type {
        let name = format!("Future<{}> (de {fname})", self.type_name(result));
        let mut futures = self.futures.borrow_mut();
        let index = futures.len();
        futures.push(crate::lir::FutureDef { result, func, name });
        Type::Future(index)
    }
    /// Named future type `Future<T>` as written by the programmer.
    fn future_named_ty(&self, result: Type, span: Span) -> Result<Type, Diagnostic> {
        self.not_region_bound(result, "Future", span)?;
        let mut futures = self.futures.borrow_mut();
        if let Some(pos) = futures
            .iter()
            .position(|f| f.func == usize::MAX && f.result == result)
        {
            return Ok(Type::Future(pos));
        }
        let name = format!("Future<{}>", self.type_name(result));
        let index = futures.len();
        futures.push(crate::lir::FutureDef {
            result,
            func: usize::MAX,
            name,
        });
        Ok(Type::Future(index))
    }
    /// Declares an async builtin on its first use.
    fn builtin_async(&self, name: &str, params: Vec<Type>, target: FnTarget) -> usize {
        if let Some(&id) = self.functions.borrow().get(name) {
            return id;
        }
        let id = self.sigs.borrow().len();
        let future = self.future_ty(Type::Unit, id, name);
        self.sigs.borrow_mut().push(Sig {
            is_async: true,
            async_result: Some(Type::Unit),
            name: name.into(),
            kind: FnKind::Free,
            owner: None,
            param_modes: vec![None; params.len()],
            params,
            result: Some(future),
            borrow_return: None,
            view_return: None,
        });
        self.functions.borrow_mut().insert(name.into(), id);
        self.queued_fns
            .borrow_mut()
            .push(FnToCompile { id, target });
        id
    }
    fn same(&self, expected: Type, actual: Type, span: Span) -> Result<(), Diagnostic> {
        if let (Type::Bytes(to), Type::Bytes(from)) = (expected, actual)
            && to != from
        {
            return Err(err(
                span,
                format!(
                    "el buffer de la región {} no puede guardarse donde se espera uno de la región {}: escaparía de su región",
                    self.region_name(from),
                    self.region_name(to)
                ),
            )
            .classify("L0011", "regiones"));
        }
        if expected != actual
            && (matches!(expected, Type::RegionList(..)) || matches!(actual, Type::RegionList(..)))
        {
            return Err(err(
                span,
                format!(
                    "tipo regional incompatible: se esperaba {}, encontrado {}",
                    self.type_name(expected),
                    self.type_name(actual)
                ),
            )
            .classify("L0011", "regiones"));
        }
        if let (Type::TaskGroup(g1), Type::TaskGroup(g2)) = (expected, actual) {
            let elem1 = self.task_groups.borrow()[g1].elem;
            let elem2 = self.task_groups.borrow()[g2].elem;
            return self.same(elem1, elem2, span);
        }
        if let (Type::Future(f1), Type::Future(f2)) = (expected, actual) {
            let res1 = self.futures.borrow()[f1].result;
            let res2 = self.futures.borrow()[f2].result;
            return self.same(res1, res2, span);
        }
        if expected == actual {
            Ok(())
        } else {
            Err(err(
                span,
                format!(
                    "tipo incompatible: se esperaba {}, encontrado {}",
                    self.type_name(expected),
                    self.type_name(actual)
                ),
            ))
        }
    }
    fn template_of(&self, t: Type) -> Option<usize> {
        match t {
            Type::Enum(id) => Some(self.enums.borrow()[id].template),
            _ => None,
        }
    }
    fn enum_args(&self, id: usize) -> Vec<Type> {
        self.enums.borrow()[id].args.clone()
    }
    fn payload(&self, id: usize, variant: usize) -> Vec<Type> {
        self.enums.borrow()[id].def.variants[variant].1.clone()
    }
    fn variant_index(&self, tid: usize, name: &str) -> Option<usize> {
        self.templates[tid]
            .variants
            .iter()
            .position(|(v, _)| v == name)
    }

    fn borrow_result(
        &self,
        function: &parser::Function,
        owner: Option<Type>,
        bindings: &[(String, Type)],
        modes: &[Option<Receiver>],
    ) -> Result<BorrowSigResult, Diagnostic> {
        let Some(t) = &function.result else {
            return Ok((function.public.then_some(Type::Unit), None, None));
        };
        let (ty, mode) = self.resolve_param(t, owner, bindings)?;
        if self.is_view(ty) {
            let receiver = match function.kind {
                FnKind::Method => Some(Receiver::Shared),
                FnKind::MutMethod => Some(Receiver::Exclusive),
                _ => None,
            };
            let params: Vec<_> = receiver
                .into_iter()
                .map(Some)
                .chain(modes.iter().copied())
                .enumerate()
                .filter_map(|(index, source)| source.map(|_| index))
                .collect();
            let mut_params: Vec<usize> = receiver
                .into_iter()
                .map(Some)
                .chain(modes.iter().copied())
                .enumerate()
                .filter_map(|(index, source)| {
                    if source == Some(Receiver::Exclusive) {
                        Some(index)
                    } else {
                        None
                    }
                })
                .collect();
            let mut fields = Vec::new();
            match ty {
                Type::Struct(sid) => {
                    for (i, (_, fty)) in self.structs.borrow()[sid].fields.iter().enumerate() {
                        let is_mut = matches!(fty, Type::MutField(_));
                        if matches!(fty, Type::SharedField(_) | Type::MutField(_)) {
                            fields.push(crate::lir::FieldContract {
                                field_index: (i * 4),
                                mode: if is_mut {
                                    Receiver::Exclusive
                                } else {
                                    Receiver::Shared
                                },
                                params: if is_mut {
                                    mut_params.clone()
                                } else {
                                    params.clone()
                                },
                                projections: Vec::new(),
                            });
                        }
                    }
                }
                Type::Enum(eid) => {
                    for (v, (_, payload)) in
                        self.enums.borrow()[eid].def.variants.iter().enumerate()
                    {
                        for (f, fty) in payload.iter().enumerate() {
                            let is_mut = matches!(fty, Type::MutField(_));
                            if matches!(fty, Type::SharedField(_) | Type::MutField(_)) {
                                fields.push(crate::lir::FieldContract {
                                    field_index: (((v * 1024 + f) * 4) + 1),
                                    mode: if is_mut {
                                        Receiver::Exclusive
                                    } else {
                                        Receiver::Shared
                                    },
                                    params: if is_mut {
                                        mut_params.clone()
                                    } else {
                                        params.clone()
                                    },
                                    projections: Vec::new(),
                                });
                            }
                        }
                    }
                }
                Type::Array(aid) => {
                    let elem = self.arrays.borrow()[aid].elem;
                    let is_mut = matches!(elem, Type::MutField(_));
                    if matches!(elem, Type::SharedField(_) | Type::MutField(_)) {
                        fields.push(crate::lir::FieldContract {
                            field_index: 2,
                            mode: if is_mut {
                                Receiver::Exclusive
                            } else {
                                Receiver::Shared
                            },
                            params: if is_mut {
                                mut_params.clone()
                            } else {
                                params.clone()
                            },
                            projections: Vec::new(),
                        });
                    }
                }
                Type::List(lid) => {
                    let elem = self.lists.borrow()[lid];
                    let is_mut = matches!(elem, Type::MutField(_));
                    if matches!(elem, Type::SharedField(_) | Type::MutField(_)) {
                        fields.push(crate::lir::FieldContract {
                            field_index: 2,
                            mode: if is_mut {
                                Receiver::Exclusive
                            } else {
                                Receiver::Shared
                            },
                            params: if is_mut {
                                mut_params.clone()
                            } else {
                                params.clone()
                            },
                            projections: Vec::new(),
                        });
                    }
                }
                _ => {}
            }
            return Ok((
                Some(ty),
                None,
                Some(crate::lir::ViewReturn { params, fields }),
            ));
        }
        let Some(mode) = mode else {
            return Ok((Some(ty), None, None));
        };
        let receiver = match function.kind {
            FnKind::Method => Some(Receiver::Shared),
            FnKind::MutMethod => Some(Receiver::Exclusive),
            _ => None,
        };
        let params: Vec<_> = receiver
            .into_iter()
            .map(Some)
            .chain(modes.iter().copied())
            .enumerate()
            .filter_map(|(index, source)| {
                source
                    .filter(|source| mode == Receiver::Shared || *source == Receiver::Exclusive)
                    .map(|_| index)
            })
            .collect();
        if params.is_empty() {
            return Err(lifetime(
                function.span,
                "un retorno de referencia necesita un parámetro prestado compatible con su modo; los propietarios locales se destruyen al retornar",
            ));
        }
        if matches!(ty, Type::Bytes(_)) {
            return Err(lifetime(
                function.span,
                "los retornos de Bytes requieren un contrato regional explícito",
            ));
        }
        Ok((
            Some(ty),
            Some(crate::lir::BorrowReturn { params, mode }),
            None,
        ))
    }

    /// Type and borrow mode of a parameter: a top-level `&T`/`&mut T` is the
    /// only position where a reference type is allowed.
    fn resolve_param(
        &self,
        t: &TypeExpr,
        owner: Option<Type>,
        params: &[(String, Type)],
    ) -> Result<(Type, Option<Receiver>), Diagnostic> {
        match t {
            TypeExpr::Ref(inner, mutable, span) => {
                let ty = match inner.as_ref() {
                    TypeExpr::Named(n, a, _) if n == "Bytes" && a.is_empty() => {
                        Type::Bytes(crate::lir::CALLER_REGION)
                    }
                    TypeExpr::Slice(elem, span) => {
                        let elem = self.resolve(elem, owner, params)?;
                        self.slice_ty(elem, *span)?
                    }
                    _ => self.resolve(inner, owner, params)?,
                };
                if matches!(ty, Type::Future(_) | Type::Task(_) | Type::TaskGroup(_)) {
                    let name = match ty {
                        Type::Future(_) => "Future",
                        Type::Task(_) => "TaskHandle",
                        _ => "TaskGroup",
                    };
                    return Err(err(*span, format!("{name} no admite préstamos (& o &mut)"))
                        .classify("L0012", "préstamos"));
                }
                Ok((
                    ty,
                    Some(if *mutable {
                        Receiver::Exclusive
                    } else {
                        Receiver::Shared
                    }),
                ))
            }
            _ => Ok((self.resolve(t, owner, params)?, None)),
        }
    }
    fn resolve(
        &self,
        t: &TypeExpr,
        owner: Option<Type>,
        params: &[(String, Type)],
    ) -> Result<Type, Diagnostic> {
        match t {
            TypeExpr::Prim(p) => Ok(*p),
            TypeExpr::Array(inner, len, span) => {
                let elem = self.resolve(inner, owner, params)?;
                self.array_ty(elem, *len, *span)
            }
            TypeExpr::Slice(_, span) => Err(err(
                *span,
                "un slice [T] solo puede recibirse como parámetro &[T] o &mut [T]",
            )),
            TypeExpr::Named(n, args, span) if n == "List" => {
                if args.len() != 1 {
                    return Err(err(*span, "List requiere 1 argumento de tipo: List<T>"));
                }
                let elem = self.resolve(&args[0], owner, params)?;
                self.list_ty(elem, *span)
            }
            TypeExpr::Ref(inner, mutable, span) => {
                let ty = self.resolve(inner, owner, params)?;
                let target = crate::lir::SharedTarget::from_type(ty).ok_or_else(|| {
                    err(
                        *span,
                        format!(
                            "no se admite una referencia a `{}` en este agregado",
                            self.type_name(ty)
                        ),
                    )
                    .classify("L0014", "préstamos")
                })?;
                Ok(if *mutable {
                    Type::MutField(target)
                } else {
                    Type::SharedField(target)
                })
            }
            TypeExpr::Named(n, _, span) if n == "Bytes" || n == "Region" => Err(err(
                *span,
                format!(
                    "{n} pertenece a una región: solo puede recibirse como parámetro &Bytes o &mut Bytes"
                ),
            )
            .classify("L0011", "regiones")),
            TypeExpr::Named(n, _, span) if n == "TaskGroup" => Err(err(
                *span,
                "TaskGroup no se puede almacenar en agregados ni colecciones, ni pasar como parámetro o retornar: pertenece al ámbito que lo crea",
            )
            .classify("L0015", "concurrencia")),
            TypeExpr::Named(n, args, span) if n == "Future" => {
                if args.len() != 1 {
                    return Err(err(*span, "Future requiere 1 argumento de tipo: Future<T>"));
                }
                let res = self.resolve(&args[0], owner, params)?;
                self.future_named_ty(res, *span)
            }
            TypeExpr::Named(n, args, span) => {
                let span = *span;
                let no_args = |what: &str| {
                    if args.is_empty() {
                        Ok(())
                    } else {
                        Err(err(
                            span,
                            format!("{what} {n} no admite argumentos de tipo"),
                        ))
                    }
                };
                if n == "Self" {
                    no_args("Self")?;
                    return owner
                        .ok_or_else(|| err(span, "Self solo está disponible dentro de impl"));
                }
                if let Some((_, t)) = params.iter().find(|(p, _)| p == n) {
                    no_args("el parámetro de tipo")?;
                    return Ok(*t);
                }
                if let Some(&tid) = self.struct_template_ids.get(n) {
                    let expected = self.struct_templates[tid].params.len();
                    if args.len() != expected {
                        return Err(err(
                            span,
                            format!(
                                "{n} requiere {expected} argumento(s) de tipo, recibidos {}",
                                args.len()
                            ),
                        ));
                    }
                    let args = args
                        .iter()
                        .map(|a| self.resolve(a, owner, params))
                        .collect::<Result<Vec<_>, _>>()?;
                    return self.instantiate_struct(tid, args, span).map(Type::Struct);
                }
                if let Some(&id) = self.struct_ids.get(n) {
                    no_args("el struct")?;
                    return Ok(Type::Struct(id));
                }
                if let Some(&tid) = self.template_ids.get(n) {
                    let expected = self.templates[tid].params.len();
                    if args.len() != expected {
                        return Err(err(
                            span,
                            format!(
                                "{n} requiere {expected} argumento(s) de tipo, recibidos {}",
                                args.len()
                            ),
                        ));
                    }
                    let args = args
                        .iter()
                        .map(|a| self.resolve(a, owner, params))
                        .collect::<Result<Vec<_>, _>>()?;
                    return self.instantiate(tid, args, span).map(Type::Enum);
                }
                Err(err(span, format!("tipo no definido: {n}")))
            }
        }
    }
    /// Concrete enum for `template<args>`, created on first use.
    fn instantiate(&self, tid: usize, args: Vec<Type>, span: Span) -> Result<usize, Diagnostic> {
        for a in &args {
            self.not_region_bound(
                *a,
                "guardarse en un enum genérico (Option, Result...)",
                span,
            )?;
        }
        if let Some(&id) = self.enum_ids.borrow().get(&(tid, args.clone())) {
            return Ok(id);
        }
        let template = &self.templates[tid];
        if args.len() != template.params.len() {
            return Err(err(
                span,
                format!(
                    "{} requiere {} argumento(s) de tipo, recibidos {}",
                    template.name,
                    template.params.len(),
                    args.len()
                ),
            ));
        }
        let key = (tid, args.clone());
        if self.instantiating.borrow().contains(&key) {
            return Err(err(
                span,
                format!(
                    "enum {} se contiene a sí mismo por valor (tamaño infinito)",
                    template.name
                ),
            ));
        }
        if self.instantiating.borrow().len() >= MAX_INSTANTIATION_DEPTH {
            return Err(err(
                span,
                format!("instanciación genérica demasiado profunda ({MAX_INSTANTIATION_DEPTH})"),
            ));
        }
        self.instantiating.borrow_mut().push(key.clone());
        let bindings: Vec<(String, Type)> = template
            .params
            .iter()
            .cloned()
            .zip(args.iter().copied())
            .collect();
        let variants = template
            .variants
            .iter()
            .map(|(name, payload)| {
                let types = payload
                    .iter()
                    .map(|t| {
                        let ty = self.resolve(t, None, &bindings)?;
                        if matches!(ty, Type::Future(_)) {
                            return Err(err(
                                span,
                                "Future no se puede almacenar en un agregado ni colecciones",
                            )
                            .classify("L0015", "concurrencia"));
                        }
                        Ok(ty)
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                Ok((name.clone(), types))
            })
            .collect::<Result<Vec<_>, Diagnostic>>();
        self.instantiating.borrow_mut().pop();
        let variants = variants?;
        let name = if args.is_empty() {
            template.name.clone()
        } else {
            let names: Vec<String> = args.iter().map(|a| self.type_name(*a)).collect();
            format!("{}<{}>", template.name, names.join(", "))
        };
        let is_view = variants.iter().any(|(_, types)| {
            types
                .iter()
                .any(|t| matches!(t, Type::SharedField(_) | Type::MutField(_)) || self.is_view(*t))
        });
        let mut enums = self.enums.borrow_mut();
        let id = enums.len();
        enums.push(EnumInfo {
            local_view: is_view,
            def: EnumDef { name, variants },
            template: tid,
            args,
        });
        self.enum_ids.borrow_mut().insert(key, id);
        Ok(id)
    }

    fn instantiate_struct(
        &self,
        tid: usize,
        args: Vec<Type>,
        span: Span,
    ) -> Result<usize, Diagnostic> {
        for a in &args {
            self.not_region_bound(*a, "guardarse en un struct genérico", span)?;
        }
        let key = (tid, args.clone());
        if let Some(&id) = self.struct_instances.borrow().get(&key) {
            return Ok(id);
        }
        let template = &self.struct_templates[tid];
        if self.instantiating_structs.borrow().contains(&key) {
            return Err(err(
                span,
                format!(
                    "struct {} se contiene a sí mismo por valor (tamaño infinito)",
                    template.name
                ),
            ));
        }
        if self.instantiating_structs.borrow().len() >= MAX_INSTANTIATION_DEPTH {
            return Err(err(
                span,
                format!("instanciación genérica demasiado profunda ({MAX_INSTANTIATION_DEPTH})"),
            ));
        }
        self.instantiating_structs.borrow_mut().push(key.clone());
        let bindings: Vec<(String, Type)> = template
            .params
            .iter()
            .map(|p| p.name.clone())
            .zip(args.iter().copied())
            .collect();
        let sid = self.structs.borrow().len();
        let name = if args.is_empty() {
            template.name.clone()
        } else {
            let names: Vec<String> = args.iter().map(|a| self.type_name(*a)).collect();
            format!("{}<{}>", template.name, names.join(", "))
        };
        self.struct_instances.borrow_mut().insert(key, sid);
        self.struct_args.borrow_mut().insert(sid, args.clone());
        self.struct_template_of.borrow_mut().insert(sid, tid);
        self.structs.borrow_mut().push(StructInfo {
            local_view: false,
            name,
            fields: Vec::new(),
            defaults: Vec::new(),
        });
        let mut fields = Vec::new();
        for f in &template.fields {
            let ty = self.resolve(&f.ty, Some(Type::Struct(sid)), &bindings)?;
            if matches!(ty, Type::Future(_)) {
                self.instantiating_structs.borrow_mut().pop();
                return Err(err(
                    f.span,
                    "Future no se puede almacenar en un agregado ni colecciones",
                )
                .classify("L0015", "concurrencia"));
            }
            if ty == Type::Unit {
                self.instantiating_structs.borrow_mut().pop();
                return Err(err(f.span, "un campo no puede ser de tipo ()"));
            }
            fields.push((f.name.clone(), ty));
        }
        let defaults = vec![None; fields.len()];
        let is_view = fields.iter().any(|(_, t)| self.is_view(*t));
        self.structs.borrow_mut()[sid].local_view = is_view;
        self.structs.borrow_mut()[sid].fields = fields;
        self.structs.borrow_mut()[sid].defaults = defaults;
        self.instantiating_structs.borrow_mut().pop();
        Ok(sid)
    }

    fn instantiate_fn(
        &self,
        tid: usize,
        type_args: Vec<Type>,
        span: Span,
    ) -> Result<usize, Diagnostic> {
        for a in &type_args {
            self.not_region_bound(*a, "pasarse a una función genérica (use &Bytes)", span)?;
        }
        let key = (tid, type_args.clone());
        if let Some(&fid) = self.fn_instances.borrow().get(&key) {
            return Ok(fid);
        }
        let template = &self.fn_templates[tid];
        if self.instantiating_fns.borrow().contains(&key) {
            return Err(err(
                span,
                format!(
                    "instanciación genérica recursiva infinita en {}",
                    template.func.name
                ),
            ));
        }
        if self.instantiating_fns.borrow().len() >= MAX_INSTANTIATION_DEPTH {
            return Err(err(
                span,
                format!("instanciación genérica demasiado profunda ({MAX_INSTANTIATION_DEPTH})"),
            ));
        }
        for (tp, actual) in template.func.type_params.iter().zip(&type_args) {
            if let Some(bound) = &tp.bound {
                let trait_id = self
                    .trait_ids
                    .get(bound)
                    .copied()
                    .ok_or_else(|| err(span, format!("trait no definido: {bound}")))?;
                if !self.implements_trait(*actual, trait_id) {
                    return Err(err(
                        span,
                        format!(
                            "el tipo {} no implementa el trait {bound} requerido por {}",
                            self.type_name(*actual),
                            tp.name
                        ),
                    ));
                }
            }
        }
        self.instantiating_fns.borrow_mut().push(key.clone());
        let bindings: Vec<(String, Type)> = template
            .func
            .type_params
            .iter()
            .map(|p| p.name.clone())
            .zip(type_args.iter().copied())
            .collect();
        let mut params = Vec::new();
        let mut param_modes = Vec::new();
        for (_, t, _) in &template.func.params {
            let (ty, mode) = self.resolve_param(t, template.owner, &bindings)?;
            if self.is_view(ty) {
                return Err(view_escape(template.func.span));
            }
            params.push(ty);
            param_modes.push(mode);
        }
        let (result, borrow_return, view_return) =
            self.borrow_result(&template.func, template.owner, &bindings, &param_modes)?;
        let rendered_args = type_args
            .iter()
            .map(|t| self.type_name(*t))
            .collect::<Vec<_>>()
            .join(", ");
        let name = match template.owner {
            Some(owner) => format!(
                "{}.{}<{rendered_args}>",
                self.type_name(owner),
                template.func.name
            ),
            None => format!("{}<{rendered_args}>", template.func.name),
        };
        let fid = self.sigs.borrow().len();
        self.sigs.borrow_mut().push(Sig {
            is_async: false,
            async_result: None,
            name,
            kind: template.func.kind,
            owner: template.owner,
            params,
            param_modes,
            result,
            borrow_return,
            view_return,
        });
        self.fn_instances.borrow_mut().insert(key, fid);
        let noalloc = get_noalloc(&template.func.attributes);
        let fn_name = self.sigs.borrow()[fid].name.clone();
        self.fn_contracts.borrow_mut().insert(
            fid,
            FnContract {
                name: fn_name,
                span: template.func.span,
                explicit_effects: template.func.effects,
                noalloc,
            },
        );
        self.queued_fns.borrow_mut().push(FnToCompile {
            id: fid,
            target: FnTarget::Specialized {
                template_id: tid,
                bindings,
            },
        });
        self.instantiating_fns.borrow_mut().pop();
        Ok(fid)
    }

    fn implements_trait(&self, ty: Type, trait_id: usize) -> bool {
        if self.trait_impls.borrow().contains_key(&(trait_id, ty)) {
            return true;
        }
        if let Type::Struct(sid) = ty
            && let Some(&stid) = self.struct_template_of.borrow().get(&sid)
        {
            let args = self
                .struct_args
                .borrow()
                .get(&sid)
                .cloned()
                .unwrap_or_default();
            for gti in &self.generic_trait_impls {
                if gti.trait_id == trait_id && gti.target_template == stid {
                    let mut ok = true;
                    for (param, actual) in gti.params.iter().zip(&args) {
                        if let Some(bound) = &param.bound
                            && let Some(&btid) = self.trait_ids.get(bound)
                            && !self.implements_trait(*actual, btid)
                        {
                            ok = false;
                            break;
                        }
                    }
                    if ok {
                        let _ = self.instantiate_generic_trait_impl(gti, sid, &args);
                        return true;
                    }
                }
            }
        }
        false
    }

    fn instantiate_generic_trait_impl(
        &self,
        gti: &GenericTraitImpl,
        sid: usize,
        sargs: &[Type],
    ) -> Result<(), Diagnostic> {
        let template = &self.struct_templates[gti.target_template];
        let bindings: Vec<(String, Type)> = template
            .params
            .iter()
            .map(|p| p.name.clone())
            .zip(sargs.iter().copied())
            .collect();
        let target_ty = Type::Struct(sid);
        self.trait_impls
            .borrow_mut()
            .insert((gti.trait_id, target_ty), 0);
        for m in &gti.methods {
            let fid = self.sigs.borrow().len();
            let mut params = Vec::new();
            let mut param_modes = Vec::new();
            for (_, t, _) in &m.params {
                let (ty, mode) = self.resolve_param(t, Some(target_ty), &bindings)?;
                params.push(ty);
                param_modes.push(mode);
            }
            let result = match &m.result {
                Some(t) => Some(self.resolve(t, Some(target_ty), &bindings)?),
                None if m.public => Some(Type::Unit),
                None => None,
            };
            let method_name = format!("{}.{}", self.type_name(target_ty), m.name);
            self.sigs.borrow_mut().push(Sig {
                is_async: false,
                async_result: None,
                name: method_name,
                kind: m.kind,
                owner: Some(target_ty),
                params,
                param_modes,
                result,
                borrow_return: None,
                view_return: None,
            });
            self.methods
                .borrow_mut()
                .insert((target_ty, m.name.clone()), fid);
            let noalloc = get_noalloc(&m.attributes);
            let fn_name = self.sigs.borrow()[fid].name.clone();
            self.fn_contracts.borrow_mut().insert(
                fid,
                FnContract {
                    name: fn_name,
                    span: m.span,
                    explicit_effects: m.effects,
                    noalloc,
                },
            );
            self.impl_methods
                .borrow_mut()
                .entry((self.traits[gti.trait_id].name.clone(), m.name.clone()))
                .or_default()
                .push(fid);
            self.queued_fns.borrow_mut().push(FnToCompile {
                id: fid,
                target: FnTarget::SpecializedMethod {
                    func: m.clone(),
                    bindings: bindings.clone(),
                },
            });
        }
        Ok(())
    }

    fn field(&self, ty: Type, name: &str, span: Span) -> Result<(usize, Type), Diagnostic> {
        let Type::Struct(sid) = ty else {
            return Err(err(
                span,
                format!(
                    "acceso a campo .{name} sobre tipo no struct {}",
                    self.type_name(ty)
                ),
            ));
        };
        let structs = self.structs.borrow();
        let s = &structs[sid];
        s.fields
            .iter()
            .position(|(f, _)| f == name)
            .map(|i| (i, s.fields[i].1))
            .ok_or_else(|| err(span, format!("el struct {} no tiene campo {name}", s.name)))
    }
    fn result_of(&self, id: usize, span: Span) -> Result<Type, Diagnostic> {
        let sigs = self.sigs.borrow();
        sigs[id].result.ok_or_else(|| {
            err(
                span,
                format!(
                    "no se puede inferir el tipo de retorno de {} (recursión o ciclo sin anotación); anote '-> Tipo'",
                    sigs[id].name
                ),
            )
            .classify(INFER_CODE, "inferencia")
        })
    }
    /// The prelude template that defines a language operator (`?`, `??`).
    fn prelude_template(&self, name: &str) -> Option<usize> {
        self.template_ids
            .get(name)
            .copied()
            .filter(|t| self.templates[*t].prelude)
    }
}

/// Binds template parameters by matching a declared payload type against the
/// type of an argument. Mismatches are reported later by ordinary checks.
fn unify(env: &Env, te: &TypeExpr, actual: Type, params: &[String], out: &mut [Option<Type>]) {
    match te {
        TypeExpr::Ref(inner, _, _) => unify(env, inner, actual, params, out),
        TypeExpr::Array(inner, _, _) | TypeExpr::Slice(inner, _) => {
            if let Some(elem) = env.elem_of(actual) {
                unify(env, inner, elem, params, out);
            }
        }
        TypeExpr::Named(n, args, _) if n == "List" && args.len() == 1 => {
            if let Type::List(_) | Type::RegionList(..) = actual
                && let Some(elem) = env.elem_of(actual)
            {
                unify(env, &args[0], elem, params, out);
            }
        }
        TypeExpr::Named(n, args, _) => {
            if args.is_empty()
                && let Some(i) = params.iter().position(|p| p == n)
            {
                if out[i].is_none() {
                    out[i] = Some(actual);
                }
                return;
            }
            if let (Some(&tid), Type::Enum(id)) = (env.template_ids.get(n), actual)
                && env.template_of(actual) == Some(tid)
            {
                for (a, t) in args.iter().zip(env.enum_args(id)) {
                    unify(env, a, t, params, out);
                }
            }
            if let (Some(&stid), Type::Struct(id)) = (env.struct_template_ids.get(n), actual)
                && env.struct_template_of.borrow().get(&id) == Some(&stid)
                && let Some(sargs) = env.struct_args.borrow().get(&id)
            {
                for (a, t) in args.iter().zip(sargs.clone()) {
                    unify(env, a, t, params, out);
                }
            }
        }
        TypeExpr::Prim(_) => {}
    }
}

fn diverges(v: &Value) -> bool {
    matches!(&v.kind, ValueKind::Match(_, arms) if arms.iter().all(|a| a.diverges))
}

#[derive(Default)]
enum ViewUse {
    #[default]
    None,
    Initialize,
    FieldBase,
}

struct Checker<'a> {
    env: &'a Env,
    owner: Option<Type>,
    scopes: Vec<HashMap<String, Binding>>,
    scope_stack: Vec<usize>,
    next: usize,
    /// Declared result, or the result inferred so far (`None` = not yet seen).
    result: Option<Type>,
    loop_depth: usize,
    globals: &'a HashMap<String, Value>,
    param_bindings: HashSet<usize>,
    bindings: Vec<(String, Type)>,
    /// True only while evaluating the top-level expression of an argument
    /// whose parameter is a reference: the only place `&lugar` may appear.
    borrow_allowed: bool,
    ref_result_allowed: bool,
    storing_value: bool,
    view_use: ViewUse,
    borrow_return: Option<crate::lir::BorrowReturn>,
    view_return: Option<crate::lir::ViewReturn>,
    /// The function being checked is `async fn`: `await` is allowed.
    is_async: bool,
    /// Source module of the body being lowered (0 for a single source string).
    source_file: u32,
}

impl Checker<'_> {
    fn push_scope(&mut self) {
        let parent = self.current_scope();
        let scope_id = self.env.next_scope(parent);
        self.scope_stack.push(scope_id);
        self.scopes.push(HashMap::new());
    }
    fn pop_scope(&mut self) {
        self.scope_stack.pop();
        self.scopes.pop();
    }
    fn current_scope(&self) -> usize {
        *self.scope_stack.last().expect("scope stack never empty")
    }
    fn bind(
        &mut self,
        name: &str,
        ty: Type,
        mutable: bool,
        span: Span,
    ) -> Result<usize, Diagnostic> {
        self.bind_ref(name, ty, mutable, None, span)
    }
    fn bind_ref(
        &mut self,
        name: &str,
        ty: Type,
        mutable: bool,
        ref_mode: Option<Receiver>,
        span: Span,
    ) -> Result<usize, Diagnostic> {
        let current_scope = self.current_scope();
        let scope = self
            .scopes
            .last_mut()
            .ok_or_else(|| err(span, "scope interno ausente"))?;
        if scope.contains_key(name) {
            return Err(err(span, format!("nombre duplicado: {name}")));
        }
        let id = self.next;
        self.next += 1;
        scope.insert(
            name.into(),
            Binding {
                id,
                ty,
                mutable,
                constant: None,
                ref_mode,
                scope: current_scope,
            },
        );
        Ok(id)
    }
    fn fresh(&mut self) -> usize {
        self.next += 1;
        self.next - 1
    }
    fn local(&self, name: &str) -> Option<&Binding> {
        self.scopes.iter().rev().find_map(|s| s.get(name))
    }
    fn is_value_name(&self, name: &str) -> bool {
        self.local(name).is_some() || self.globals.contains_key(name)
    }
    fn lookup(&self, name: &str, span: Span) -> Result<Binding, Diagnostic> {
        self.local(name)
            .cloned()
            .or_else(|| {
                self.globals.get(name).map(|v| Binding {
                    id: 0,
                    ty: v.ty,
                    mutable: false,
                    constant: Some(v.clone()),
                    ref_mode: None,
                    scope: 0,
                })
            })
            .ok_or_else(|| {
                if name == "self" {
                    err(span, "self solo está disponible en métodos fn/mut fn")
                } else if self.env.struct_ids.contains_key(name) {
                    err(
                        span,
                        format!("{name} es un tipo; construya con {name}(campo: valor)"),
                    )
                } else if self.env.template_ids.contains_key(name) {
                    err(span, format!("{name} es un enum; use {name}.Variante"))
                } else {
                    err(span, format!("símbolo no definido: {name}"))
                }
            })
    }
    fn set_result(&mut self, ty: Type, span: Span) -> Result<(), Diagnostic> {
        if !self
            .view_return
            .as_ref()
            .is_some_and(|_| self.result == Some(ty))
        {
            self.env.not_region_bound(ty, "devolverse", span)?;
        }
        match self.result {
            Some(expected) => self.env.same(expected, ty, span),
            None => {
                self.result = Some(ty);
                Ok(())
            }
        }
    }
    fn binding_by_id(&self, id: usize) -> Option<Binding> {
        self.scopes
            .iter()
            .rev()
            .find_map(|s| s.values().find(|b| b.id == id).cloned())
    }
    fn name_by_id(&self, id: usize) -> Option<String> {
        self.scopes.iter().rev().find_map(|s| {
            s.iter()
                .find_map(|(k, b)| if b.id == id { Some(k.clone()) } else { None })
        })
    }
    fn call_return(&self, kind: &ValueKind) -> Option<crate::lir::BorrowReturn> {
        match kind {
            ValueKind::Call(f, _)
            | ValueKind::MethodCall(f, ..)
            | ValueKind::TempMethodCall(f, ..) => self.env.sigs.borrow()[*f].borrow_return.clone(),
            _ => None,
        }
    }
    fn returning_reference(
        &mut self,
        expr: &parser::Expr,
        mode: Receiver,
    ) -> Result<Instruction, Diagnostic> {
        let source = match &expr.kind {
            ExprKind::Unary(op, target) if op == "&" || op == "&mut" => {
                if (op == "&mut") != (mode == Receiver::Exclusive) {
                    return Err(lifetime(
                        expr.span,
                        "el modo del préstamo no coincide con el retorno",
                    ));
                }
                target.as_ref()
            }
            _ => expr,
        };
        self.ref_result_allowed = std::ptr::eq(source, expr);
        let value = self.expr(source, 0, self.result)?;
        self.env.same(
            self.result.expect("retorno prestado anotado"),
            value.ty,
            value.span,
        )?;
        if let Some(callee) = self.call_return(&value.kind) {
            if callee.mode != mode {
                return Err(lifetime(
                    expr.span,
                    "el modo del resultado de la llamada no coincide con el retorno",
                ));
            }
        } else {
            if !addressable(&value) {
                return Err(lifetime(
                    expr.span,
                    "la referencia devuelta debe apuntar al parámetro prestado, no a un temporal",
                ));
            }
            let name = root_name(source);
            let binding = self.lookup(&name, source.span)?;
            if binding.ref_mode.is_none() && !self.param_bindings.contains(&binding.id) {
                return Err(lifetime(
                    source.span,
                    format!(
                        "la referencia a {name} apunta a almacenamiento local que se destruye al retornar; use el parámetro prestado"
                    ),
                ));
            }
            if mode == Receiver::Exclusive && !binding.mutable {
                return Err(lifetime(
                    expr.span,
                    "el lugar del retorno &mut no es mutable",
                ));
            }
        }
        Ok(Instruction::ReturnRef(mode, value))
    }

    fn check_return_borrow(&self, v: &Value) -> Result<(), Diagnostic> {
        if let ValueKind::Borrow(p, _) = &v.kind {
            if !self.param_bindings.contains(&p.root) {
                return Err(err(
                    v.span,
                    "no se puede devolver una referencia a una variable local que deja de existir",
                ));
            }
            if let Some(b) = self.binding_by_id(p.root)
                && b.ref_mode.is_none()
            {
                return Err(err(
                    v.span,
                    "no se puede devolver una referencia a una variable local que deja de existir",
                ));
            }
        }
        Ok(())
    }
    /// Resolves an assignable/borrowable expression to a place rooted at a
    /// runtime local. Returns `None` for non-place expressions.
    fn place(&self, e: &parser::Expr) -> Option<Result<(Place, Binding, Type), Diagnostic>> {
        match &e.kind {
            ExprKind::Name(n) => {
                if !self.is_value_name(n) && self.env.unqualified.contains_key(n) {
                    return None;
                }
                let binding = match self.lookup(n, e.span) {
                    Ok(b) => b,
                    Err(e) => return Some(Err(e)),
                };
                if binding.constant.is_some() {
                    return None;
                }
                let ty = binding.ty;
                Some(Ok((
                    Place {
                        root: binding.id,
                        fields: Vec::new(),
                    },
                    binding,
                    ty,
                )))
            }
            ExprKind::Field(base, name) => {
                if let ExprKind::Name(n) = &base.kind
                    && !self.is_value_name(n)
                    && (self.env.template_ids.contains_key(n)
                        || self.env.struct_ids.contains_key(n))
                {
                    return None;
                }
                Some(self.place(base)?.and_then(|(mut p, b, ty)| {
                    let (index, field_ty) = self.env.field(ty, name, e.span)?;
                    p.fields.push(index);
                    let out_ty = match field_ty {
                        Type::SharedField(target) | Type::MutField(target) => target.referent(),
                        _ => field_ty,
                    };
                    Ok((p, b, out_ty))
                }))
            }
            _ => None,
        }
    }
    fn args(
        &mut self,
        args: &[parser::Expr],
        depth: usize,
        expected: &[Type],
        stored: bool,
    ) -> Result<Vec<Value>, Diagnostic> {
        let mut out = Vec::new();
        for (i, a) in args.iter().enumerate() {
            if let ExprKind::Named(n, _) = &a.kind {
                return Err(err(
                    a.span,
                    format!("argumento con nombre {n}: solo se admite en constructores de struct"),
                ));
            }
            out.push(if stored {
                self.stored_expr(a, depth + 1, expected.get(i).copied())?
            } else {
                self.expr(a, depth + 1, expected.get(i).copied())?
            });
        }
        Ok(out)
    }
    /// Evaluates call arguments against parameter borrow modes. A `&T`
    /// parameter accepts `&lugar` or a plain place, which is borrowed
    /// implicitly (spec §6); `&mut T` requires an explicit `&mut lugar`; a
    /// by-value parameter never accepts a borrow.
    fn ref_args(
        &mut self,
        args: &[parser::Expr],
        depth: usize,
        expected: &[Type],
        modes: &[Option<Receiver>],
    ) -> Result<Vec<Value>, Diagnostic> {
        let mut out = Vec::new();
        for (i, a) in args.iter().enumerate() {
            if let ExprKind::Named(n, _) = &a.kind {
                return Err(err(
                    a.span,
                    format!("argumento con nombre {n}: solo se admite en constructores de struct"),
                ));
            }
            let mode = modes.get(i).copied().flatten();
            let explicit = matches!(&a.kind, ExprKind::Unary(op, _) if op == "&" || op == "&mut");
            if mode == Some(Receiver::Shared) && !explicit {
                let Some(place) = self.place(a) else {
                    return Err(err(
                        a.span,
                        format!(
                            "el parámetro {} es una referencia (&T): pase una variable o un campo, que se presta automáticamente",
                            i + 1
                        ),
                    ));
                };
                let (place, _, ty) = place?;
                out.push(Value {
                    ty,
                    span: a.span,
                    kind: ValueKind::Borrow(place, false),
                });
                continue;
            }
            self.borrow_allowed = mode.is_some();
            let value = self.expr(a, depth + 1, expected.get(i).copied())?;
            if mode.is_none() && matches!(value.kind, ValueKind::Borrow(..)) {
                return Err(err(
                    a.span,
                    format!(
                        "el parámetro {} se recibe por valor, no por referencia: quite '&'",
                        i + 1
                    ),
                ));
            }
            if mode == Some(Receiver::Shared) && matches!(value.kind, ValueKind::Borrow(_, true)) {
                return Err(err(
                    a.span,
                    format!("el parámetro {} es &T: pase '&' en lugar de '&mut'", i + 1),
                ));
            }
            out.push(value);
        }
        Ok(out)
    }
    fn check_args(&self, id: usize, args: &[Value], span: Span) -> Result<(), Diagnostic> {
        let sigs = self.env.sigs.borrow();
        let sig = &sigs[id];
        if sig.params.len() != args.len() {
            return Err(err(
                span,
                format!(
                    "número de argumentos incompatible en {}: se esperaban {}, recibidos {}",
                    sig.name,
                    sig.params.len(),
                    args.len()
                ),
            ));
        }
        for (i, ((expected, actual), mode)) in sig
            .params
            .iter()
            .zip(args)
            .zip(&sig.param_modes)
            .enumerate()
        {
            // A `&Bytes`/`&mut Bytes` parameter borrows a buffer of whatever
            // region the caller is in: the call ends before that region does.
            let caller_buffer = mode.is_some()
                && *expected == Type::Bytes(crate::lir::CALLER_REGION)
                && matches!(actual.ty, Type::Bytes(_));
            // A `&[T]`/`&mut [T]` parameter borrows any array, list or slice
            // of the same element type as a view.
            let slice_view = mode.is_some()
                && matches!(expected, Type::Slice(_))
                && matches!(
                    actual.ty,
                    Type::Array(_) | Type::List(_) | Type::RegionList(..) | Type::Slice(_)
                )
                && self.env.elem_of(*expected) == self.env.elem_of(actual.ty);
            if !caller_buffer && !slice_view {
                self.env.same(*expected, actual.ty, actual.span)?;
            }
            match mode {
                Some(Receiver::Exclusive) => match &actual.kind {
                    ValueKind::Borrow(p, true) => {
                        if let Some(b) = self.binding_by_id(p.root)
                            && !b.mutable
                            && b.ref_mode != Some(Receiver::Exclusive)
                        {
                            return Err(err(
                                actual.span,
                                format!(
                                    "no se puede prestar mutablemente la variable inmutable {}",
                                    self.name_by_id(p.root).unwrap_or_default()
                                ),
                            ));
                        }
                    }
                    _ => {
                        return Err(err(
                            actual.span,
                            format!(
                                "se esperaba un préstamo mutable (&mut) para el parámetro {}",
                                i + 1
                            ),
                        ));
                    }
                },
                Some(Receiver::Shared) => {}
                None => {}
            }
        }
        Ok(())
    }
    fn call(
        &mut self,
        id: usize,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
    ) -> Result<(Vec<Value>, Type), Diagnostic> {
        let (params, modes) = {
            let sigs = self.env.sigs.borrow();
            (sigs[id].params.clone(), sigs[id].param_modes.clone())
        };
        let args = self.ref_args(args, depth, &params, &modes)?;
        self.check_args(id, &args, span)?;
        Ok((args, self.env.result_of(id, span)?))
    }
    fn construct(
        &mut self,
        sid: usize,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
    ) -> Result<ValueKind, Diagnostic> {
        let env = self.env;
        let (info_name, info_defaults, info_fields) = {
            let structs = env.structs.borrow();
            let info = &structs[sid];
            (
                info.name.clone(),
                info.defaults.clone(),
                info.fields.clone(),
            )
        };
        if info_defaults.len() != info_fields.len() {
            return Err(err(
                span,
                "const requiere expresión constante; constructores de struct no permitidos aquí",
            ));
        }
        let mut inits = Vec::new();
        let mut seen = HashSet::new();
        for arg in args {
            let ExprKind::Named(name, value) = &arg.kind else {
                return Err(err(
                    arg.span,
                    format!(
                        "constructor de {}: use argumentos con nombre campo: valor",
                        info_name
                    ),
                ));
            };
            let (index, ty) = env.field(Type::Struct(sid), name, arg.span)?;
            if !seen.insert(index) {
                return Err(err(
                    arg.span,
                    format!("campo {name} inicializado más de una vez"),
                ));
            }
            let value = if let Type::SharedField(target) = ty {
                let ExprKind::Unary(op, source) = &value.kind else {
                    return Err(err(value.span, "inicialice el campo prestado con &lugar")
                        .classify("L0014", "préstamos"));
                };
                if op != "&" || !named_place(source) {
                    return Err(err(
                        value.span,
                        "el campo compartido requiere &lugar con almacenamiento existente",
                    )
                    .classify("L0014", "préstamos"));
                }
                let borrowed = self.expr(source, depth + 1, Some(target.referent()))?;
                if !addressable(&borrowed) {
                    return Err(err(
                        value.span,
                        "el campo no puede prestar un temporal ni una propiedad calculada",
                    )
                    .classify("L0014", "préstamos"));
                }
                env.same(target.referent(), borrowed.ty, borrowed.span)?;
                Value {
                    ty,
                    span: value.span,
                    kind: ValueKind::StoredBorrow(Box::new(borrowed)),
                }
            } else if let Type::MutField(target) = ty {
                let ExprKind::Unary(op, source) = &value.kind else {
                    return Err(
                        err(value.span, "inicialice el campo prestado con &mut lugar")
                            .classify("L0014", "préstamos"),
                    );
                };
                if op != "&mut" || !named_place(source) {
                    return Err(err(
                        value.span,
                        "el campo mutable requiere &mut lugar con almacenamiento existente",
                    )
                    .classify("L0014", "préstamos"));
                }
                let borrowed = self.expr(source, depth + 1, Some(target.referent()))?;
                if !addressable(&borrowed) {
                    return Err(err(
                        value.span,
                        "el campo no puede prestar un temporal ni una propiedad calculada",
                    )
                    .classify("L0014", "préstamos"));
                }
                if let Some(res) = self.place(source) {
                    let (_, binding, _) = res?;
                    if !binding.mutable && binding.ref_mode != Some(Receiver::Exclusive) {
                        return Err(err(
                            value.span,
                            "no se puede prestar mutablemente una variable inmutable",
                        )
                        .classify("L0012", "préstamos"));
                    }
                }
                env.same(target.referent(), borrowed.ty, borrowed.span)?;
                Value {
                    ty,
                    span: value.span,
                    kind: ValueKind::StoredBorrow(Box::new(borrowed)),
                }
            } else {
                self.stored_expr(value, depth + 1, Some(ty))?
            };
            env.same(ty, value.ty, value.span)?;
            inits.push((index, value));
        }
        for (index, (name, _)) in info_fields.iter().enumerate() {
            if seen.contains(&index) {
                continue;
            }
            match &info_defaults[index] {
                Some(default) => inits.push((
                    index,
                    Value {
                        span,
                        ..default.clone()
                    },
                )),
                None => {
                    return Err(err(
                        span,
                        format!(
                            "falta el campo obligatorio {name} al construir {}",
                            info_name
                        ),
                    ));
                }
            }
        }
        Ok(ValueKind::Construct(sid, inits))
    }
    /// Constructs variant `v` of template `tid`. The concrete instance comes from
    /// the expected type when compatible, otherwise from the payload types.
    fn variant(
        &mut self,
        tid: usize,
        v: usize,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
        expected: Option<Type>,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        let env = self.env;
        let template = &env.templates[tid];
        let (vname, declared) = &template.variants[v];
        if declared.len() != args.len() {
            return Err(err(
                span,
                format!(
                    "la variante {vname} espera {} valor(es), recibidos {}",
                    declared.len(),
                    args.len()
                ),
            ));
        }
        let from_expected = expected.and_then(|t| match t {
            Type::Enum(id) if env.template_of(t) == Some(tid) => Some(id),
            _ => None,
        });
        let (id, values) = match from_expected {
            Some(id) => {
                let payload = env.payload(id, v);
                (id, self.args(args, depth, &payload, true)?)
            }
            None if template.params.is_empty() => {
                let id = env.instantiate(tid, Vec::new(), span)?;
                let payload = env.payload(id, v);
                (id, self.args(args, depth, &payload, true)?)
            }
            None => {
                let values = self.args(args, depth, &[], true)?;
                let mut bound = vec![None; template.params.len()];
                for (te, value) in declared.iter().zip(&values) {
                    unify(env, te, value.ty, &template.params, &mut bound);
                }
                let mut resolved = Vec::new();
                for (param, t) in template.params.iter().zip(bound) {
                    resolved.push(t.ok_or_else(|| {
                        err(
                            span,
                            format!(
                                "no se puede inferir el parámetro {param} de {}; anote el tipo (p.ej. let x: {}<...> = ...)",
                                template.name, template.name
                            ),
                        )
                    })?);
                }
                (env.instantiate(tid, resolved, span)?, values)
            }
        };
        for (t, value) in env.payload(id, v).iter().zip(&values) {
            env.same(*t, value.ty, value.span)?;
        }
        Ok((Type::Enum(id), ValueKind::Variant(id, v, values)))
    }
    fn stored_expr(
        &mut self,
        e: &parser::Expr,
        depth: usize,
        expected: Option<Type>,
    ) -> Result<Value, Diagnostic> {
        self.storing_value = true;
        self.expr(e, depth, expected)
    }
    fn expr(
        &mut self,
        e: &parser::Expr,
        depth: usize,
        expected: Option<Type>,
    ) -> Result<Value, Diagnostic> {
        if depth > 128 {
            return Err(err(e.span, "expresión demasiado profunda (128)"));
        }
        // Only the outermost expression of a reference argument may borrow.
        let borrow_allowed = std::mem::take(&mut self.borrow_allowed);
        let ref_result_allowed = std::mem::take(&mut self.ref_result_allowed);
        let storing_value = std::mem::take(&mut self.storing_value);
        let view_use = std::mem::take(&mut self.view_use);
        let env = self.env;
        let (ty, kind) = match &e.kind {
            ExprKind::Int(v) => (Type::Int, ValueKind::Int(*v)),
            ExprKind::Float(v) => {
                if expected == Some(Type::F32) {
                    (Type::F32, ValueKind::Float(*v))
                } else {
                    (Type::Float, ValueKind::Float(*v))
                }
            }
            ExprKind::Bool(v) => (Type::Bool, ValueKind::Bool(*v)),
            ExprKind::Await(inner) => {
                if !self.is_async {
                    return Err(async_error(
                        e.span,
                        "await solo se puede usar dentro de una función async",
                    ));
                }
                if let ExprKind::MethodCall(base, name, args) = &inner.kind
                    && name == JOIN_ALL
                {
                    if !args.is_empty() {
                        return Err(async_error(inner.span, "joinAll no toma argumentos"));
                    }
                    let group = self.expr(base, depth + 1, None)?;
                    let result = match group.ty {
                        Type::TaskGroup(gid) => env.task_groups.borrow()[gid].elem,
                        Type::List(_) => {
                            let task = env.group_task(group.ty).ok_or_else(|| {
                                async_error(
                                    group.span,
                                    "joinAll requiere un TaskGroup o una lista de TaskHandle",
                                )
                            })?;
                            env.futures.borrow()[task].result
                        }
                        _ => {
                            return Err(async_error(
                                group.span,
                                "joinAll requiere un TaskGroup o una lista de TaskHandle",
                            ));
                        }
                    };
                    if result == Type::Unit {
                        return Err(async_error(
                            group.span,
                            "joinAll requiere resultados distintos de ()",
                        ));
                    }
                    (
                        env.list_ty(result, e.span)?,
                        ValueKind::JoinAll(Box::new(group)),
                    )
                } else if let ExprKind::Call(name, args) = &inner.kind
                    && name == JOIN_ALL
                {
                    let [arg] = &args[..] else {
                        return Err(async_error(
                            inner.span,
                            "joinAll requiere una lista de TaskHandle",
                        ));
                    };
                    let group = self.expr(arg, depth + 1, None)?;
                    let result = match group.ty {
                        Type::TaskGroup(gid) => env.task_groups.borrow()[gid].elem,
                        Type::List(_) => {
                            let task = env.group_task(group.ty).ok_or_else(|| {
                                async_error(group.span, "joinAll requiere una lista de TaskHandle")
                            })?;
                            env.futures.borrow()[task].result
                        }
                        _ => {
                            return Err(async_error(
                                group.span,
                                "joinAll requiere una lista de TaskHandle",
                            ));
                        }
                    };
                    if result == Type::Unit {
                        return Err(async_error(
                            group.span,
                            "joinAll requiere resultados distintos de ()",
                        ));
                    }
                    (
                        env.list_ty(result, e.span)?,
                        ValueKind::JoinAll(Box::new(group)),
                    )
                } else if let ExprKind::Call(name, args) = &inner.kind
                    && name == JOIN
                {
                    if args.len() != 2 {
                        return Err(async_error(
                            inner.span,
                            "join requiere exactamente dos TaskHandle",
                        ));
                    }
                    let handles: [Value; 2] = self
                        .args(args, depth + 1, &[], false)?
                        .try_into()
                        .unwrap_or_else(|_| unreachable!("se verificó la aridad"));
                    let result = |handle: &Value| match handle.ty {
                        Type::Task(id) => Ok(env.futures.borrow()[id].result),
                        _ => Err(async_error(
                            handle.span,
                            format!(
                                "join espera un TaskHandle; encontrado {}",
                                env.type_name(handle.ty)
                            ),
                        )),
                    };
                    let pair = env.join_pair([result(&handles[0])?, result(&handles[1])?]);
                    (pair, ValueKind::Join(Box::new(handles)))
                } else {
                    let future = self.expr(inner, depth + 1, None)?;
                    let (Type::Future(index) | Type::Task(index)) = future.ty else {
                        return Err(async_error(
                            future.span,
                            format!(
                                "await espera el future de una llamada async o un TaskHandle; encontrado {}",
                                env.type_name(future.ty)
                            ),
                        ));
                    };
                    let result = env.futures.borrow()[index].result;
                    (result, ValueKind::Await(Box::new(future)))
                }
            }
            ExprKind::Spawn(inner) => {
                if !self.is_async {
                    return Err(async_error(
                        e.span,
                        "spawn solo se puede usar dentro de una función async: la tarea pertenece al scope asíncrono que la crea",
                    ));
                }
                let future = self.expr(inner, depth + 1, None)?;
                let Type::Future(index) = future.ty else {
                    return Err(async_error(
                        future.span,
                        format!(
                            "spawn espera la llamada a una función async; encontrado {}",
                            env.type_name(future.ty)
                        ),
                    ));
                };
                (Type::Task(index), ValueKind::Spawn(Box::new(future)))
            }
            ExprKind::Unit => (Type::Unit, ValueKind::Unit),
            ExprKind::Text(s) => (Type::Text, ValueKind::Text(s.clone())),
            ExprKind::Interpolate(parts) => {
                let mut values = Vec::new();
                for part in parts {
                    let value = self.expr(part, depth + 1, None)?;
                    if !printable(value.ty) {
                        return Err(err(
                            part.span,
                            format!(
                                "tipo {} no convertible a Text en interpolación",
                                env.type_name(value.ty)
                            ),
                        ));
                    }
                    values.push(value);
                }
                let value = Value {
                    ty: Type::Text,
                    span: e.span,
                    kind: ValueKind::Interpolate(values),
                };
                // Fold only pure, successful constants. Runtime failures and effects remain runtime.
                let value = crate::consteval::evaluate(&value).unwrap_or(value);
                (Type::Text, value.kind)
            }
            ExprKind::Name(n) => {
                if !self.is_value_name(n)
                    && let Some(&(tid, v)) = env.unqualified.get(n)
                {
                    self.variant(tid, v, &[], e.span, depth, expected)?
                } else {
                    let b = self.lookup(n, e.span)?;
                    if let Type::Region(r) = b.ty {
                        return Err(err(
                            e.span,
                            format!(
                                "la región {} solo puede usarse como receptor de .bytes(n)",
                                env.region_name(r)
                            ),
                        )
                        .classify("L0011", "regiones"));
                    }
                    match b.constant {
                        Some(v) => (v.ty, v.kind),
                        None => (b.ty, ValueKind::Local(b.id)),
                    }
                }
            }
            ExprKind::Named(n, _) => {
                return Err(err(
                    e.span,
                    format!("argumento con nombre {n}: solo se admite en constructores de struct"),
                ));
            }
            ExprKind::GenericCall(n, type_args, args) => {
                self.call_expr(n, Some(type_args), args, e.span, depth, expected)?
            }
            ExprKind::Call(n, args) => self.call_expr(n, None, args, e.span, depth, expected)?,
            ExprKind::Field(base, name) => {
                let type_name = match &base.kind {
                    ExprKind::Name(n) if !self.is_value_name(n) => Some(n.as_str()),
                    _ => None,
                };
                if let Some(n) = type_name
                    && (env.struct_ids.contains_key(n) || env.struct_template_ids.contains_key(n))
                {
                    return Err(err(
                        e.span,
                        format!("{n}.{name}: el acceso a campos requiere una instancia"),
                    ));
                }
                match type_name.and_then(|n| env.template_ids.get(n)) {
                    Some(&tid) => {
                        let v = self.variant_of(tid, name, e.span)?;
                        self.variant(tid, v, &[], e.span, depth, expected)?
                    }
                    None => {
                        self.view_use = ViewUse::FieldBase;
                        let base = self.expr(base, depth + 1, None)?;
                        if base.ty == Type::Text && name == "byteLength" {
                            (Type::Int, ValueKind::Length(Box::new(base)))
                        } else if env.elem_of(base.ty).is_some() {
                            match (name.as_str(), base.ty) {
                                ("length", _) => (Type::Int, ValueKind::Length(Box::new(base))),
                                ("capacity", Type::List(_) | Type::RegionList(..)) => {
                                    (Type::Int, ValueKind::Capacity(Box::new(base)))
                                }
                                _ => {
                                    return Err(err(
                                        e.span,
                                        format!(
                                            "{} no tiene .{name}: las colecciones tienen .length (y List también .capacity)",
                                            env.type_name(base.ty)
                                        ),
                                    ));
                                }
                            }
                        } else {
                            let (index, ty) = env.field(base.ty, name, e.span)?;
                            if let Type::SharedField(target) | Type::MutField(target) = ty {
                                (
                                    target.referent(),
                                    ValueKind::SharedField(Box::new(base), index),
                                )
                            } else {
                                (ty, ValueKind::Field(Box::new(base), index))
                            }
                        }
                    }
                }
            }
            ExprKind::ArrayLit(items) => {
                let hint = expected.and_then(|t| match t {
                    Type::Array(_) => env.elem_of(t),
                    _ => None,
                });
                let (elem, values) = self.elements(items, hint, e.span, depth, false)?;
                (
                    env.array_ty(elem, values.len(), e.span)?,
                    ValueKind::ArrayLit(values),
                )
            }
            ExprKind::ListLit(items) => {
                let hint = expected.and_then(|t| match t {
                    Type::List(_) | Type::RegionList(..) => env.elem_of(t),
                    _ => None,
                });
                let (elem, values) = self.elements(items, hint, e.span, depth, true)?;
                (env.list_ty(elem, e.span)?, ValueKind::ListLit(values))
            }
            ExprKind::Index(base, index) => {
                self.view_use = ViewUse::Initialize;
                let base = self.expr(base, depth + 1, None)?;
                let Some(elem) = env.elem_of(base.ty) else {
                    return Err(err(
                        e.span,
                        format!("{} no se puede indexar", env.type_name(base.ty)),
                    ));
                };
                let index = self.expr(index, depth + 1, Some(Type::Int))?;
                env.same(Type::Int, index.ty, index.span)?;
                check_constant_index(env, &base, &index)?;
                let ty = match elem {
                    Type::SharedField(target) | Type::MutField(target)
                        if !storing_value
                            && !matches!(
                                expected,
                                Some(Type::SharedField(_) | Type::MutField(_))
                            ) =>
                    {
                        target.referent()
                    }
                    _ => elem,
                };
                (ty, ValueKind::Index(Box::new(base), Box::new(index)))
            }
            ExprKind::GenericMethodCall(base, name, type_args, args) => {
                self.method_call(base, name, Some(type_args), args, e.span, depth, expected)?
            }
            ExprKind::MethodCall(base, name, args) => {
                self.method_call(base, name, None, args, e.span, depth, expected)?
            }
            ExprKind::Match(scrutinee, arms) => {
                let v = self.match_expr(scrutinee, arms, e.span, depth, expected, false)?;
                (v.ty, v.kind)
            }
            ExprKind::Try(inner) => self.try_expr(inner, e.span, depth)?,
            ExprKind::Unary(op, x) => {
                if op == "&" || op == "&mut" {
                    if storing_value
                        || matches!(expected, Some(Type::SharedField(_) | Type::MutField(_)))
                    {
                        let mutable = op == "&mut";
                        if !named_place(x) {
                            return Err(err(
                                e.span,
                                if mutable {
                                    "el campo mutable requiere &mut lugar con almacenamiento existente"
                                } else {
                                    "el campo compartido requiere &lugar con almacenamiento existente"
                                },
                            )
                            .classify("L0014", "préstamos"));
                        }
                        let target_ty = match expected {
                            Some(Type::SharedField(t) | Type::MutField(t)) => Some(t.referent()),
                            _ => None,
                        };
                        let borrowed = self.expr(x, depth + 1, target_ty)?;
                        if !addressable(&borrowed) {
                            return Err(err(
                                e.span,
                                "el campo no puede prestar un temporal ni una propiedad calculada",
                            )
                            .classify("L0014", "préstamos"));
                        }
                        if mutable && let Some(res) = self.place(x) {
                            let (_, binding, _) = res?;
                            if !binding.mutable && binding.ref_mode != Some(Receiver::Exclusive) {
                                return Err(err(
                                    e.span,
                                    "no se puede prestar mutablemente una variable inmutable",
                                )
                                .classify("L0012", "préstamos"));
                            }
                        }
                        let target =
                            crate::lir::SharedTarget::from_type(borrowed.ty).ok_or_else(|| {
                                err(
                                    e.span,
                                    format!(
                                        "no se admite una referencia a `{}` en este agregado",
                                        env.type_name(borrowed.ty)
                                    ),
                                )
                                .classify("L0014", "préstamos")
                            })?;
                        let ty = if mutable {
                            Type::MutField(target)
                        } else {
                            Type::SharedField(target)
                        };
                        (ty, ValueKind::StoredBorrow(Box::new(borrowed)))
                    } else {
                        if !borrow_allowed {
                            return Err(err(
                                e.span,
                                "un préstamo (&, &mut) solo puede pasarse directamente como argumento a un parámetro de referencia; guardarlo o devolverlo requiere anotaciones de vida aún no implementadas",
                            ));
                        }
                        let mutable = op == "&mut";
                        let Some(res) = self.place(x) else {
                            return Err(err(
                                e.span,
                                "préstamo requiere un lugar en memoria (variable o campo)",
                            ));
                        };
                        let (place, binding, ty) = res?;
                        if mutable && !binding.mutable {
                            return Err(err(
                                e.span,
                                "no se puede prestar mutablemente una variable inmutable",
                            ));
                        }
                        (ty, ValueKind::Borrow(place, mutable))
                    }
                } else {
                    let v = self.expr(x, depth + 1, None)?;
                    if (op == "!" && v.ty != Type::Bool) || (op == "-" && !numeric(v.ty)) {
                        return Err(err(e.span, "operador unario incompatible con tipo"));
                    }
                    (v.ty, ValueKind::Unary(op.clone(), Box::new(v)))
                }
            }
            ExprKind::Binary(op, a, b) if op == "??" => {
                self.coalesce(a, b, e.span, depth, expected)?
            }
            ExprKind::Binary(op, a, b) => {
                let a = self.expr(a, depth + 1, None)?;
                let b = self.expr(b, depth + 1, Some(a.ty))?;
                let ty = binary_type(env, op, &a, &b)?;
                (ty, ValueKind::Binary(op.clone(), Box::new(a), Box::new(b)))
            }
        };
        if env.is_view(ty) {
            let allowed = match view_use {
                ViewUse::Initialize => {
                    matches!(
                        kind,
                        ValueKind::Local(_)
                            | ValueKind::Construct(..)
                            | ValueKind::Call(..)
                            | ValueKind::MethodCall(..)
                            | ValueKind::TempMethodCall(..)
                            | ValueKind::Variant(..)
                            | ValueKind::ArrayLit(..)
                            | ValueKind::ListLit(..)
                            | ValueKind::Match(..)
                            | ValueKind::Index(..)
                    )
                }
                ViewUse::FieldBase => matches!(
                    kind,
                    ValueKind::Local(_)
                        | ValueKind::Call(..)
                        | ValueKind::MethodCall(..)
                        | ValueKind::TempMethodCall(..)
                ),
                ViewUse::None => false,
            };
            if !allowed {
                return Err(view_escape(e.span));
            }
        }
        if storing_value && self.call_return(&kind).is_some() {
            return Err(aggregate_escape(e.span));
        }
        if self.call_return(&kind).is_some()
            && (!ref_result_allowed || matches!(kind, ValueKind::TempMethodCall(..)))
        {
            return Err(lifetime(
                e.span,
                "use el resultado prestado como inicializador de let o retorno prestado, con un receptor que sea un lugar",
            ));
        }
        Ok(Value {
            ty,
            kind,
            span: e.span,
        })
    }
    fn variant_of(&self, tid: usize, name: &str, span: Span) -> Result<usize, Diagnostic> {
        self.env.variant_index(tid, name).ok_or_else(|| {
            err(
                span,
                format!(
                    "el enum {} no tiene la variante {name}",
                    self.env.templates[tid].name
                ),
            )
        })
    }
    fn call_expr(
        &mut self,
        n: &str,
        type_args: Option<&[TypeExpr]>,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
        expected: Option<Type>,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        let env = self.env;
        if self.is_value_name(n) {
            return Err(err(span, format!("símbolo no invocable: {n}")));
        }
        if let Some(&stid) = env.struct_template_ids.get(n) {
            let template = &env.struct_templates[stid];
            let param_names: Vec<String> = template.params.iter().map(|p| p.name.clone()).collect();
            let concrete_args = if let Some(t_args) = type_args {
                if t_args.len() != template.params.len() {
                    return Err(err(
                        span,
                        format!(
                            "{n} requiere {} argumento(s) de tipo, recibidos {}",
                            template.params.len(),
                            t_args.len()
                        ),
                    ));
                }
                t_args
                    .iter()
                    .map(|a| env.resolve(a, self.owner, &self.bindings))
                    .collect::<Result<Vec<_>, _>>()?
            } else {
                let mut bound = vec![None; template.params.len()];
                for arg in args {
                    if let ExprKind::Named(name, val) = &arg.kind
                        && let Some(f) = template.fields.iter().find(|f| f.name == *name)
                    {
                        let v = self.expr(val, depth + 1, None)?;
                        unify(env, &f.ty, v.ty, &param_names, &mut bound);
                    }
                }
                if let Some(Type::Struct(sid)) = expected
                    && env.struct_template_of.borrow().get(&sid) == Some(&stid)
                    && let Some(sargs) = env.struct_args.borrow().get(&sid)
                {
                    for (b, a) in bound.iter_mut().zip(sargs) {
                        if b.is_none() {
                            *b = Some(*a);
                        }
                    }
                }
                let mut resolved = Vec::new();
                for (param, t) in template.params.iter().zip(bound) {
                    resolved.push(t.ok_or_else(|| {
                        err(
                            span,
                            format!(
                                "no se puede inferir el parámetro {} de {}; anote el tipo",
                                param.name, template.name
                            ),
                        )
                    })?);
                }
                resolved
            };
            let sid = env.instantiate_struct(stid, concrete_args, span)?;
            let kind = self.construct(sid, args, span, depth)?;
            return Ok((Type::Struct(sid), kind));
        }
        if let Some(&sid) = env.struct_ids.get(n) {
            if let Some(t_args) = type_args
                && !t_args.is_empty()
            {
                return Err(err(
                    span,
                    format!("el struct {n} no admite argumentos de tipo"),
                ));
            }
            return Ok((Type::Struct(sid), self.construct(sid, args, span, depth)?));
        }
        if let Some(&(tid, v)) = env.unqualified.get(n) {
            return self.variant(tid, v, args, span, depth, expected);
        }
        if env.template_ids.contains_key(n) {
            return Err(err(
                span,
                format!("{n} es un enum; construya con {n}.Variante(...)"),
            ));
        }
        if n == JOIN {
            return Err(async_error(
                span,
                "join solo se admite como await join(a, b)",
            ));
        }
        if n == JOIN_ALL {
            return Err(async_error(
                span,
                "joinAll solo se admite como await joinAll(tareas)",
            ));
        }
        if n == TASK_GROUP {
            if !self.is_async {
                return Err(async_error(span, "taskGroup requiere un ámbito async"));
            }
            if let Some(t_args) = type_args {
                if t_args.len() != 1 {
                    return Err(async_error(
                        span,
                        "taskGroup<T>() requiere 1 argumento de tipo",
                    ));
                }
                if !args.is_empty() {
                    return Err(async_error(span, "taskGroup<T>() no toma argumentos"));
                }
                let elem = env.resolve(&t_args[0], self.owner, &self.bindings)?;
                let group_ty = env.task_group_ty(elem, self.current_scope(), span)?;
                return Ok((group_ty, ValueKind::ListLit(Vec::new())));
            }
            let [arg] = args else {
                return Err(async_error(
                    span,
                    "taskGroup requiere el nombre de una función async o tipo genérico taskGroup<T>()",
                ));
            };
            let ExprKind::Name(name) = &arg.kind else {
                return Err(async_error(
                    arg.span,
                    "taskGroup requiere el nombre de una función async o tipo genérico taskGroup<T>()",
                ));
            };
            let result = env
                .free_function(name, self.source_file, arg.span)?
                .and_then(|id| env.sigs.borrow()[id].result)
                .and_then(|ty| match ty {
                    Type::Future(task) => Some(env.futures.borrow()[task].result),
                    _ => None,
                })
                .ok_or_else(|| {
                    async_error(
                        arg.span,
                        "taskGroup requiere el nombre de una función async",
                    )
                })?;
            let group_ty = env.task_group_ty(result, self.current_scope(), span)?;
            return Ok((group_ty, ValueKind::ListLit(Vec::new())));
        }
        if n == SLEEP_MS {
            if args.len() != 1 || type_args.is_some() {
                return Err(async_error(
                    span,
                    "sleepMs requiere una duración Int en milisegundos",
                ));
            }
            let args = self.args(args, depth, &[Type::Int], false)?;
            env.same(Type::Int, args[0].ty, args[0].span)?;
            if let Ok(Value {
                kind: ValueKind::Int(ms),
                ..
            }) = crate::consteval::evaluate(&args[0])
                && !(0..=MAX_SLEEP_MS).contains(&ms)
            {
                return Err(async_error(args[0].span, INVALID_SLEEP));
            }
            let id = env.builtin_async(SLEEP_MS, vec![Type::Int], FnTarget::Sleep);
            let result = env.sigs.borrow()[id].result.expect("sleepMs tiene future");
            return Ok((result, ValueKind::Call(id, args)));
        }
        if n == YIELD_NOW {
            if !args.is_empty() {
                return Err(async_error(span, "yieldNow no toma argumentos"));
            }
            let id = env.builtin_async(YIELD_NOW, Vec::new(), FnTarget::YieldNow);
            let result = env.sigs.borrow()[id].result.expect("yieldNow tiene future");
            return Ok((result, ValueKind::Call(id, Vec::new())));
        }
        if n == "writeBytes" {
            if args.len() != 2 || type_args.is_some() {
                return Err(err(
                    span,
                    "writeBytes requiere (ruta: Text, bytes: List<Int>)",
                ));
            }
            let args = self.args(args, depth, &[], false)?;
            env.same(Type::Text, args[0].ty, args[0].span)?;
            let valid_bytes = match args[1].ty {
                Type::List(l) => env.lists.borrow().get(l).copied() == Some(Type::Int),
                _ => false,
            };
            if !valid_bytes {
                return Err(err(
                    args[1].span,
                    "writeBytes requiere una lista List<Int> de bytes",
                ));
            }
            return Ok((Type::Int, ValueKind::Platform(PlatformOp::WriteBytes, args)));
        }
        if let Some(op) = PlatformOp::named(n) {
            let params = op.params();
            if args.len() != params.len() || type_args.is_some() {
                return Err(err(
                    span,
                    format!("{n} requiere {} argumento(s) y ningún tipo", params.len()),
                ));
            }
            let args = self.args(args, depth, params, false)?;
            for (arg, ty) in args.iter().zip(params) {
                env.same(*ty, arg.ty, arg.span)?;
            }
            let result = match op {
                PlatformOp::ArgCount => Type::Int,
                PlatformOp::PrintError => Type::Unit,
                PlatformOp::WriteBytes => unreachable!("handled before generic platform calls"),
                PlatformOp::Arg | PlatformOp::ReadText => {
                    let id = env.template_ids["Result"];
                    Type::Enum(env.instantiate(id, vec![Type::Text, Type::Int], span)?)
                }
            };
            return Ok((result, ValueKind::Platform(op, args)));
        }
        if n == "print" {
            let args = self.args(args, depth, &[], false)?;
            if args.len() != 1 {
                return Err(err(span, "print requiere exactamente un argumento"));
            }
            let a = args
                .into_iter()
                .next()
                .ok_or_else(|| err(span, "argumento ausente"))?;
            if !printable(a.ty) {
                return Err(err(span, "print soporta Int/Float/Bool/Text"));
            }
            return Ok((Type::Unit, ValueKind::Print(Box::new(a))));
        }
        if n == "Float" || n == "f64" || n == "f32" || n == "Int" {
            if args.len() != 1 {
                return Err(err(span, format!("{n} requiere exactamente un argumento")));
            }
            let target_ty = match n {
                "Float" | "f64" => Type::Float,
                "f32" => Type::F32,
                "Int" => Type::Int,
                _ => unreachable!(),
            };
            let val = self.expr(&args[0], depth + 1, None)?;
            if !numeric(val.ty) {
                return Err(err(
                    val.span,
                    format!("no se puede convertir {} a {n}", env.type_name(val.ty)),
                ));
            }
            return if val.ty == target_ty {
                Ok((target_ty, val.kind))
            } else {
                Ok((target_ty, ValueKind::Convert(Box::new(val), target_ty)))
            };
        }
        if let Some(tid) = env.free_template(n, self.source_file, span)? {
            let template = &env.fn_templates[tid];
            let param_names: Vec<String> = template
                .func
                .type_params
                .iter()
                .map(|p| p.name.clone())
                .collect();
            let concrete_args = if let Some(t_args) = type_args {
                if t_args.len() != template.func.type_params.len() {
                    return Err(err(
                        span,
                        format!(
                            "{n} requiere {} argumento(s) de tipo, recibidos {}",
                            template.func.type_params.len(),
                            t_args.len()
                        ),
                    ));
                }
                t_args
                    .iter()
                    .map(|a| env.resolve(a, self.owner, &self.bindings))
                    .collect::<Result<Vec<_>, _>>()?
            } else {
                let mut bound = vec![None; template.func.type_params.len()];
                for (f_param, arg) in template.func.params.iter().zip(args) {
                    self.borrow_allowed = matches!(f_param.1, TypeExpr::Ref(..));
                    let v = self.expr(arg, depth + 1, None)?;
                    unify(env, &f_param.1, v.ty, &param_names, &mut bound);
                }
                let mut resolved = Vec::new();
                for (param, t) in template.func.type_params.iter().zip(bound) {
                    resolved.push(t.ok_or_else(|| {
                        err(
                            span,
                            format!(
                                "no se puede inferir el parámetro {} de {}; anote el tipo (p.ej. {n}<...>(...))",
                                param.name, template.func.name
                            ),
                        )
                    })?);
                }
                resolved
            };
            let fid = env.instantiate_fn(tid, concrete_args, span)?;
            let (args, result) = self.call(fid, args, span, depth)?;
            return Ok((result, ValueKind::Call(fid, args)));
        }
        let id = env
            .free_function(n, self.source_file, span)?
            .ok_or_else(|| err(span, format!("función no definida: {n}")))?;
        let (args, result) = self.call(id, args, span, depth)?;
        Ok((result, ValueKind::Call(id, args)))
    }
    /// Elements of an array or list literal: one common type, guided by the
    /// expected element type; an empty literal needs that expected type.
    fn elements(
        &mut self,
        items: &[parser::Expr],
        hint: Option<Type>,
        span: Span,
        depth: usize,
        list: bool,
    ) -> Result<(Type, Vec<Value>), Diagnostic> {
        let what = if list { "lista" } else { "array" };
        let mut elem = hint;
        let mut values = Vec::new();
        for item in items {
            self.view_use = ViewUse::Initialize;
            let v = self.stored_expr(item, depth + 1, elem)?;
            match elem {
                Some(t) if list => self.env.same_list_element(t, v.ty, v.span)?,
                Some(t) => self.env.same(t, v.ty, v.span)?,
                None => elem = Some(v.ty),
            }
            values.push(v);
        }
        let elem = elem.ok_or_else(|| {
            err(
                span,
                format!(
                    "{what} vacío: anote su tipo (p.ej. let a: [Int; 0] = [] o let l: List<Int> = List[])"
                ),
            )
        })?;
        if elem == Type::Unit {
            return Err(err(span, format!("un {what} no puede contener valores ()")));
        }
        Ok((elem, values))
    }
    /// Built-in methods of `List<T>`; `lista` must be a mutable place.
    #[allow(clippy::too_many_arguments)]
    fn list_method(
        &mut self,
        base: &parser::Expr,
        binding: &Binding,
        ty: Type,
        name: &str,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        let env = self.env;
        let elem = env.elem_of(ty).expect("list element");
        if env.group_task(ty).is_some() && !matches!(name, "push" | "reserve") {
            return Err(async_error(
                span,
                "un grupo de tareas solo admite push, reserve y await joinAll",
            ));
        }
        if !binding.mutable && binding.ref_mode != Some(Receiver::Exclusive) {
            return Err(err(
                span,
                format!("{name} modifica la lista: declárela con var o recíbala como &mut"),
            ));
        }
        let arity = |n: usize| -> Result<(), Diagnostic> {
            if args.len() == n {
                Ok(())
            } else {
                Err(err(span, format!("{name} espera {n} argumento(s)")))
            }
        };
        self.view_use = ViewUse::FieldBase;
        let list = self.expr(base, depth + 1, None)?;
        Ok(match name {
            "push" => {
                arity(1)?;
                let v = self.stored_expr(&args[0], depth + 1, Some(elem))?;
                if matches!(ty, Type::List(_)) {
                    env.same_list_element(elem, v.ty, v.span)?;
                } else {
                    env.same(elem, v.ty, v.span)?;
                }
                (Type::Unit, ValueKind::ListPush(Box::new(list), Box::new(v)))
            }
            "pop" => {
                arity(0)?;
                let option = env
                    .prelude_template("Option")
                    .ok_or_else(|| err(span, "prelude sin Option"))?;
                let id = env.instantiate(option, vec![elem], span)?;
                let some = env.variant_index(option, "Some").expect("Some");
                let none = env.variant_index(option, "None").expect("None");
                (
                    Type::Enum(id),
                    ValueKind::ListPop(Box::new(list), id, some, none),
                )
            }
            "reserve" => {
                arity(1)?;
                let n = self.expr(&args[0], depth + 1, Some(Type::Int))?;
                env.same(Type::Int, n.ty, n.span)?;
                (
                    Type::Unit,
                    ValueKind::ListReserve(Box::new(list), Box::new(n)),
                )
            }
            _ => {
                return Err(err(
                    span,
                    format!(
                        "List no tiene el método {name}: use push, pop, reserve, .length o .capacity"
                    ),
                ));
            }
        })
    }
    /// Built-in operations of regions and region buffers.
    #[allow(clippy::too_many_arguments)]
    fn region_method(
        &mut self,
        place: Place,
        binding: Binding,
        ty: Type,
        name: &str,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        let mut ints = Vec::new();
        for a in args {
            let v = self.expr(a, depth + 1, Some(Type::Int))?;
            self.env.same(Type::Int, v.ty, v.span)?;
            ints.push(v);
        }
        let count = ints.len();
        let arity = |n: usize| -> Result<(), Diagnostic> {
            if count == n {
                Ok(())
            } else {
                Err(err(span, format!("{name} espera {n} argumento(s) Int")))
            }
        };
        let mut ints = ints.into_iter().map(Box::new);
        Ok(match (ty, name) {
            (Type::Region(r), "bytes") => {
                arity(1)?;
                (
                    Type::Bytes(r),
                    ValueKind::RegionBytes(place, ints.next().unwrap()),
                )
            }
            (Type::Bytes(_), "len") => {
                arity(0)?;
                (Type::Int, ValueKind::BytesLen(place))
            }
            (Type::Bytes(_), "get") => {
                arity(1)?;
                (Type::Int, ValueKind::BytesGet(place, ints.next().unwrap()))
            }
            (Type::Bytes(_), "set") => {
                arity(2)?;
                if !binding.mutable && binding.ref_mode != Some(Receiver::Exclusive) {
                    return Err(err(
                        span,
                        "set modifica el buffer: declárelo con var o recíbalo como &mut Bytes",
                    ));
                }
                let i = ints.next().unwrap();
                (
                    Type::Unit,
                    ValueKind::BytesSet(place, i, ints.next().unwrap()),
                )
            }
            (Type::Region(_), _) => {
                return Err(err(
                    span,
                    format!("las regiones solo tienen .bytes(n), no .{name}"),
                ));
            }
            _ => {
                return Err(err(
                    span,
                    format!("Bytes solo tiene .len(), .get(i) y .set(i, v), no .{name}"),
                ));
            }
        })
    }
    #[allow(clippy::too_many_arguments)]
    fn task_group_method(
        &mut self,
        base: &parser::Expr,
        binding: &Binding,
        _ty: Type,
        gid: usize,
        name: &str,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        let env = self.env;
        let elem = env.task_groups.borrow()[gid].elem;
        if name == JOIN_ALL {
            return Err(async_error(
                span,
                "joinAll solo se admite como await grupo.joinAll() o await joinAll(grupo)",
            ));
        }
        if !matches!(name, "spawn" | "push" | "reserve") {
            return Err(async_error(
                span,
                "un grupo de tareas solo admite spawn, push, reserve y await joinAll",
            ));
        }
        if !binding.mutable && binding.ref_mode != Some(Receiver::Exclusive) {
            return Err(err(
                span,
                format!("{name} modifica el grupo de tareas: declárelo con var"),
            ));
        }
        let arity = |n: usize| -> Result<(), Diagnostic> {
            if args.len() == n {
                Ok(())
            } else {
                Err(err(span, format!("{name} espera {n} argumento(s)")))
            }
        };
        self.view_use = ViewUse::FieldBase;
        let group_val = self.expr(base, depth + 1, None)?;
        match name {
            "spawn" => {
                arity(1)?;
                let mut v = self.expr(&args[0], depth + 1, None)?;
                if let Type::Future(task_id) = v.ty {
                    let res = env.futures.borrow()[task_id].result;
                    env.same(elem, res, v.span)?;
                    v = Value {
                        ty: Type::Task(task_id),
                        span: v.span,
                        kind: ValueKind::Spawn(Box::new(v)),
                    };
                } else if let Type::Task(task_id) = v.ty {
                    let res = env.futures.borrow()[task_id].result;
                    env.same(elem, res, v.span)?;
                } else {
                    return Err(async_error(
                        v.span,
                        "spawn requiere una llamada a una función async o un TaskHandle",
                    ));
                }
                Ok((
                    Type::Unit,
                    ValueKind::ListPush(Box::new(group_val), Box::new(v)),
                ))
            }
            "push" => {
                arity(1)?;
                let v = self.expr(&args[0], depth + 1, None)?;
                let Type::Task(task_id) = v.ty else {
                    return Err(async_error(
                        v.span,
                        "push en TaskGroup requiere un TaskHandle",
                    ));
                };
                let res = env.futures.borrow()[task_id].result;
                env.same(elem, res, v.span)?;
                Ok((
                    Type::Unit,
                    ValueKind::ListPush(Box::new(group_val), Box::new(v)),
                ))
            }
            "reserve" => {
                arity(1)?;
                let n = self.expr(&args[0], depth + 1, Some(Type::Int))?;
                env.same(Type::Int, n.ty, n.span)?;
                Ok((
                    Type::Unit,
                    ValueKind::ListReserve(Box::new(group_val), Box::new(n)),
                ))
            }
            _ => unreachable!(),
        }
    }
    #[allow(clippy::too_many_arguments)]
    fn method_call(
        &mut self,
        base: &parser::Expr,
        name: &str,
        type_args: Option<&[TypeExpr]>,
        args: &[parser::Expr],
        span: Span,
        depth: usize,
        expected: Option<Type>,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        let env = self.env;
        // `Tipo.metodo(...)` / `Enum.Variante(...)`: the name is a type, not a value.
        if let ExprKind::Name(n) = &base.kind
            && !self.is_value_name(n)
        {
            let owner = if let Some(&sid) = env.struct_ids.get(n) {
                Some(Type::Struct(sid))
            } else if let Some(&tid) = env.template_ids.get(n) {
                if let Some(v) = env.variant_index(tid, name) {
                    return self.variant(tid, v, args, span, depth, expected);
                }
                if !env.templates[tid].params.is_empty() {
                    return Err(err(
                        span,
                        format!("el enum {n} no tiene la variante {name}"),
                    ));
                }
                Some(Type::Enum(env.instantiate(tid, Vec::new(), span)?))
            } else {
                None
            };
            if let Some(owner) = owner {
                let id = self.method_id(owner, name, span)?;
                if env.sigs.borrow()[id].kind != FnKind::Static {
                    return Err(err(
                        span,
                        format!("{n}.{name} es un método de instancia; invóquelo sobre un valor"),
                    ));
                }
                let (args, result) = self.call(id, args, span, depth)?;
                return Ok((result, ValueKind::Call(id, args)));
            }
        }
        let place = self.place(base).transpose()?;
        if let Some((p, _, Type::Region(r))) = &place
            && name == "list"
        {
            let Some([element]) = type_args else {
                return Err(err(span, "use región.list<T>() con un tipo de elemento"));
            };
            if !args.is_empty() {
                return Err(err(span, "región.list<T>() no recibe argumentos"));
            }
            let elem = env.resolve(element, self.owner, &self.bindings)?;
            if elem == Type::Unit {
                return Err(err(span, "una lista regional no puede contener valores ()"));
            }
            let Type::List(id) = env.list_ty(elem, span)? else {
                unreachable!()
            };
            return Ok((Type::RegionList(id, *r), ValueKind::RegionList(p.clone())));
        }
        if let Some((p, binding, ty)) = &place
            && matches!(ty, Type::Region(_) | Type::Bytes(_))
        {
            return self.region_method(p.clone(), binding.clone(), *ty, name, args, span, depth);
        }
        if let Some((_, binding, ty @ Type::TaskGroup(gid))) = &place {
            return self.task_group_method(
                base,
                &binding.clone(),
                *ty,
                *gid,
                name,
                args,
                span,
                depth,
            );
        }
        if let Some((_, binding, ty @ (Type::List(_) | Type::RegionList(..)))) = &place {
            return self.list_method(base, &binding.clone(), *ty, name, args, span, depth);
        }
        // A list stored in an element (`filas[i].push(x)`, `g[0].items.push(x)`):
        // the mutability is that of the root binding.
        if place.is_none() && element_place(base) {
            let probe = self.expr(base, depth + 1, None)?;
            if let Type::List(_) | Type::RegionList(..) = probe.ty {
                let binding = self.lookup(&root_name(base), span)?;
                if binding.ref_mode == Some(Receiver::Shared) {
                    return Err(err(
                        span,
                        format!(
                            "{name} modifica la lista: no se puede a través de una referencia de lectura"
                        ),
                    ));
                }
                return self.list_method(base, &binding, probe.ty, name, args, span, depth);
            }
        }
        if let Some((_, _, ty @ (Type::Array(_) | Type::Slice(_)))) = &place {
            return Err(err(
                span,
                format!(
                    "{} no tiene métodos; use .length o índices",
                    env.type_name(*ty)
                ),
            ));
        }
        let (receiver_ty, temp) = match &place {
            Some((_, _, ty)) => (*ty, None),
            None => {
                let v = self.expr(base, depth + 1, None)?;
                (v.ty, Some(v))
            }
        };
        if receiver_ty == Type::Text && name == "byteAt" {
            if type_args.is_some() || args.len() != 1 {
                return Err(err(
                    span,
                    "Text.byteAt espera un índice Int y ningún argumento de tipo",
                ));
            }
            let base = match temp {
                Some(v) => v,
                None => {
                    self.view_use = ViewUse::FieldBase;
                    self.expr(base, depth + 1, None)?
                }
            };
            let index = self.expr(&args[0], depth + 1, Some(Type::Int))?;
            env.same(Type::Int, index.ty, index.span)?;
            return Ok((
                Type::Int,
                ValueKind::TextByte(Box::new(base), Box::new(index)),
            ));
        }
        if let Type::TaskGroup(_) = receiver_ty {
            if name == JOIN_ALL {
                return Err(async_error(
                    span,
                    "joinAll solo se admite como await grupo.joinAll() o await joinAll(grupo)",
                ));
            }
            return Err(err(
                span,
                format!("{name} modifica el grupo de tareas: declárelo con var"),
            ));
        }
        if receiver_ty.is_region_bound() {
            return Err(err(
                span,
                "guarde el buffer en una variable de su región antes de usarlo",
            ));
        }
        let id = self.method_id(receiver_ty, name, span)?;
        let receiver = match env.sigs.borrow()[id].kind {
            FnKind::Static => {
                return Err(err(
                    span,
                    format!(
                        "{name} es static fn; invóquelo como {}.{name}()",
                        env.type_name(receiver_ty)
                    ),
                ));
            }
            FnKind::MutMethod => Receiver::Exclusive,
            _ => Receiver::Shared,
        };
        let (args, result) = self.call(id, args, span, depth)?;
        let kind = match (place, temp) {
            (Some((place, binding, _)), _) => {
                if receiver == Receiver::Exclusive && !binding.mutable {
                    return Err(err(
                        span,
                        format!(
                            "mut fn {name} requiere un receptor mutable (binding var o self en mut fn)"
                        ),
                    ));
                }
                ValueKind::MethodCall(id, place, receiver, args)
            }
            (None, _) if receiver == Receiver::Exclusive => {
                return Err(err(
                    span,
                    format!("mut fn {name} requiere un receptor guardado en un binding var"),
                ));
            }
            (None, Some(temp)) => ValueKind::TempMethodCall(id, Box::new(temp), args),
            (None, None) => unreachable!("receiver is a place or a temporary"),
        };
        Ok((result, kind))
    }
    fn method_id(&self, owner: Type, name: &str, span: Span) -> Result<usize, Diagnostic> {
        if let Some(&id) = self.env.methods.borrow().get(&(owner, name.to_string())) {
            return Ok(id);
        }
        if let Type::Struct(sid) = owner
            && let Some(&stid) = self.env.struct_template_of.borrow().get(&sid)
        {
            let sargs = self
                .env
                .struct_args
                .borrow()
                .get(&sid)
                .cloned()
                .unwrap_or_default();
            for mt in &self.env.method_templates {
                if mt.target_template == stid && mt.func.name == name {
                    return self.instantiate_method_template(mt, sid, &sargs, span);
                }
            }
        }
        for trait_info in &self.env.traits {
            if trait_info.methods.iter().any(|m| m.name == name)
                && let Some(&tid) = self.env.trait_ids.get(&trait_info.name)
                && self.env.implements_trait(owner, tid)
                && let Some(&id) = self.env.methods.borrow().get(&(owner, name.to_string()))
            {
                return Ok(id);
            }
        }
        Err(err(
            span,
            format!(
                "el tipo {} no tiene método {name}",
                self.env.type_name(owner)
            ),
        ))
    }

    fn instantiate_method_template(
        &self,
        mt: &MethodTemplate,
        sid: usize,
        sargs: &[Type],
        _span: Span,
    ) -> Result<usize, Diagnostic> {
        let template = &self.env.struct_templates[mt.target_template];
        let bindings: Vec<(String, Type)> = template
            .params
            .iter()
            .map(|p| p.name.clone())
            .zip(sargs.iter().copied())
            .collect();
        let owner = Some(Type::Struct(sid));
        let mut params = Vec::new();
        let mut param_modes = Vec::new();
        for (_, t, _) in &mt.func.params {
            let (ty, mode) = self.env.resolve_param(t, owner, &bindings)?;
            if self.env.is_view(ty) {
                return Err(view_escape(mt.func.span));
            }
            params.push(ty);
            param_modes.push(mode);
        }
        let (result, borrow_return, view_return) =
            self.env
                .borrow_result(&mt.func, owner, &bindings, &param_modes)?;
        let fid = self.env.sigs.borrow().len();
        let name = format!("{}.{}", self.env.type_name(Type::Struct(sid)), mt.func.name);
        self.env.sigs.borrow_mut().push(Sig {
            is_async: false,
            async_result: None,
            name,
            kind: mt.func.kind,
            owner,
            params,
            param_modes,
            result,
            borrow_return,
            view_return,
        });
        self.env
            .methods
            .borrow_mut()
            .insert((Type::Struct(sid), mt.func.name.clone()), fid);
        let noalloc = get_noalloc(&mt.func.attributes);
        let fn_name = self.env.sigs.borrow()[fid].name.clone();
        self.env.fn_contracts.borrow_mut().insert(
            fid,
            FnContract {
                name: fn_name,
                span: mt.func.span,
                explicit_effects: mt.func.effects,
                noalloc,
            },
        );
        self.env.queued_fns.borrow_mut().push(FnToCompile {
            id: fid,
            target: FnTarget::SpecializedMethod {
                func: mt.func.clone(),
                bindings,
            },
        });
        Ok(fid)
    }
    /// `match`: evaluates the scrutinee once; arms are typed, checked for
    /// reachability and exhaustiveness. With `discard` the arm values are
    /// statements (match used as a statement) and need not agree in type.
    fn match_expr(
        &mut self,
        scrutinee: &parser::Expr,
        arms: &[parser::MatchArm],
        span: Span,
        depth: usize,
        expected: Option<Type>,
        discard: bool,
    ) -> Result<Value, Diagnostic> {
        let env = self.env;
        self.view_use = ViewUse::Initialize;
        let scrutinee = self.expr(scrutinee, depth + 1, None)?;
        let ty = scrutinee.ty;
        if arms.is_empty() {
            return Err(err(span, "match sin brazos"));
        }
        let mut lowered = Vec::new();
        let mut result: Option<Type> = None;
        for arm in arms {
            self.push_scope();
            let mut bindings = Vec::new();
            let pattern = self.pattern(&arm.pattern, ty, &mut bindings);
            let body = pattern.and_then(|pattern| {
                let hint = result.or(expected);
                let (body, value, diverges) = self.arm_body(&arm.body, hint, discard)?;
                Ok((pattern, body, value, diverges))
            });
            self.pop_scope();
            let (pattern, body, value, diverges) = body?;
            if let Some(v) = &value {
                match result {
                    Some(t) => env.same(t, v.ty, v.span)?,
                    None => result = Some(v.ty),
                }
            }
            lowered.push(Arm {
                pattern,
                bindings,
                body,
                value,
                diverges,
            });
        }
        let patterns: Vec<&Pattern> = lowered.iter().map(|a| &a.pattern).collect();
        match exhaustive::check(env, ty, &patterns) {
            Ok(()) => {}
            Err(Issue::Unreachable(i)) => {
                return Err(err(
                    arms[i].span,
                    "patrón inalcanzable: los brazos anteriores ya cubren estos valores",
                ));
            }
            Err(Issue::Missing(w)) => {
                return Err(err(
                    span,
                    format!(
                        "match no exhaustivo sobre {}: falta el caso {w}",
                        env.type_name(ty)
                    ),
                ));
            }
        }
        // A value-less, non-diverging arm in value position yields ().
        let ty_result = if discard {
            Type::Unit
        } else {
            result.unwrap_or(Type::Unit)
        };
        if !discard && ty_result != Type::Unit {
            for arm in &lowered {
                if arm.value.is_none() && !arm.diverges {
                    return Err(err(
                        span,
                        format!(
                            "un brazo no produce valor; se esperaba {}",
                            env.type_name(ty_result)
                        ),
                    ));
                }
            }
        }
        Ok(Value {
            ty: ty_result,
            span,
            kind: ValueKind::Match(Box::new(scrutinee), lowered),
        })
    }
    fn arm_body(
        &mut self,
        stmts: &[Stmt],
        expected: Option<Type>,
        discard: bool,
    ) -> Result<(Vec<Instruction>, Option<Value>, bool), Diagnostic> {
        self.push_scope();
        let result = self.arm_body_inner(stmts, expected, discard);
        self.pop_scope();
        result
    }
    fn arm_body_inner(
        &mut self,
        stmts: &[Stmt],
        expected: Option<Type>,
        discard: bool,
    ) -> Result<(Vec<Instruction>, Option<Value>, bool), Diagnostic> {
        let tail = match stmts.last() {
            Some(Stmt::Expr(e, false)) if !discard => Some(e),
            _ => None,
        };
        let head = if tail.is_some() {
            &stmts[..stmts.len() - 1]
        } else {
            stmts
        };
        let (mut body, mut div) = self.block(head, false, false)?;
        let mut value = None;
        if let Some(e) = tail {
            let v = self.expr(e, 0, expected)?;
            if div || diverges(&v) {
                div = true;
                body.push(Instruction::Eval(v));
            } else {
                value = Some(v);
            }
        }
        Ok((body, value, div))
    }
    fn pattern(
        &mut self,
        p: &parser::Pattern,
        ty: Type,
        bindings: &mut Vec<(usize, Type)>,
    ) -> Result<Pattern, Diagnostic> {
        let env = self.env;
        let mismatch = |what: &str| {
            err(
                p.span,
                format!("patrón {what} incompatible con tipo {}", env.type_name(ty)),
            )
        };
        Ok(match &p.kind {
            PatternKind::Wild => Pattern::Wild,
            PatternKind::Int(n) if ty == Type::Int => Pattern::Int(*n),
            PatternKind::Int(n) => return Err(mismatch(&n.to_string())),
            PatternKind::Bool(b) if ty == Type::Bool => Pattern::Bool(*b),
            PatternKind::Bool(b) => return Err(mismatch(&b.to_string())),
            PatternKind::Text(s) if ty == Type::Text => Pattern::Text(s.clone()),
            PatternKind::Text(_) => return Err(mismatch("Text")),
            PatternKind::Float(_) => {
                return Err(err(
                    p.span,
                    "patrones Float no permitidos: su exhaustividad no está definida (spec §4)",
                ));
            }
            PatternKind::Name(n) if env.unqualified.contains_key(n) => {
                self.variant_pattern(p, None, n, &[], ty, bindings)?
            }
            PatternKind::Name(n) => {
                if let Some(tid) = env.template_of(ty)
                    && env.variant_index(tid, n).is_some()
                {
                    return Err(err(
                        p.span,
                        format!(
                            "{n} es una variante; califíquela: {}.{n}",
                            env.templates[tid].name
                        ),
                    ));
                }
                let (bound_ty, is_mut, ref_mode) = match ty {
                    Type::SharedField(target) => (target.referent(), false, Some(Receiver::Shared)),
                    Type::MutField(target) => (target.referent(), true, Some(Receiver::Exclusive)),
                    _ => (ty, false, None),
                };
                let id = self.bind_ref(n, bound_ty, is_mut, ref_mode, p.span)?;
                bindings.push((id, ty));
                Pattern::Bind(id)
            }
            PatternKind::Variant(qualifier, name, subs) => {
                self.variant_pattern(p, qualifier.as_deref(), name, subs, ty, bindings)?
            }
        })
    }
    fn variant_pattern(
        &mut self,
        p: &parser::Pattern,
        qualifier: Option<&str>,
        name: &str,
        subs: &[parser::Pattern],
        ty: Type,
        bindings: &mut Vec<(usize, Type)>,
    ) -> Result<Pattern, Diagnostic> {
        let env = self.env;
        let shown = match qualifier {
            Some(q) => format!("{q}.{name}"),
            None => name.to_string(),
        };
        let (Type::Enum(id), Some(tid)) = (ty, env.template_of(ty)) else {
            return Err(err(
                p.span,
                format!("patrón {shown} incompatible con tipo {}", env.type_name(ty)),
            ));
        };
        let template = &env.templates[tid];
        if qualifier.is_none()
            && let Some(&(other, _)) = env.unqualified.get(name)
            && other != tid
        {
            return Err(err(
                p.span,
                format!("patrón {shown} incompatible con tipo {}", env.type_name(ty)),
            ));
        }
        match qualifier {
            Some(q) if q != template.name => {
                return Err(err(
                    p.span,
                    if env.template_ids.contains_key(q) {
                        format!("patrón {shown} incompatible con tipo {}", env.type_name(ty))
                    } else {
                        format!("tipo no definido: {q}")
                    },
                ));
            }
            None if !template.prelude => {
                return Err(err(
                    p.span,
                    format!("califique la variante: {}.{name}", template.name),
                ));
            }
            _ => {}
        }
        let v = env.variant_index(tid, name).ok_or_else(|| {
            err(
                p.span,
                format!("el enum {} no tiene la variante {name}", template.name),
            )
        })?;
        let payload = env.payload(id, v);
        if payload.len() != subs.len() {
            return Err(err(
                p.span,
                format!(
                    "la variante {shown} tiene {} dato(s); el patrón da {}",
                    payload.len(),
                    subs.len()
                ),
            ));
        }
        let mut lowered = Vec::new();
        for (sub, t) in subs.iter().zip(payload) {
            lowered.push(self.pattern(sub, t, bindings)?);
        }
        Ok(Pattern::Variant(id, v, lowered))
    }
    /// `expr?`: early return of `None`/`Err(e)`, otherwise the payload.
    fn try_expr(
        &mut self,
        inner: &parser::Expr,
        span: Span,
        depth: usize,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        if self.borrow_return.is_some() {
            return Err(lifetime(
                span,
                "? puede retornar un valor propietario y esta función devuelve una referencia",
            ));
        }
        let env = self.env;
        let option = env.prelude_template("Option");
        let result = env.prelude_template("Result");
        self.view_use = ViewUse::Initialize;
        let value = self.expr(inner, depth + 1, None)?;
        let tid = env
            .template_of(value.ty)
            .filter(|t| Some(*t) == option || Some(*t) == result)
            .ok_or_else(|| {
                err(
                    span,
                    format!(
                        "? requiere Option o Result, encontrado {}",
                        env.type_name(value.ty)
                    ),
                )
            })?;
        let Some(fn_result) = self.result else {
            return Err(err(
                span,
                "? requiere que la función declare su retorno (-> Option<...> o -> Result<...>)",
            ));
        };
        if env.template_of(fn_result) != Some(tid) {
            return Err(err(
                span,
                format!(
                    "? sobre {} requiere que la función devuelva {}, no {}; no hay conversión implícita",
                    env.type_name(value.ty),
                    env.templates[tid].name,
                    env.type_name(fn_result)
                ),
            ));
        }
        let (Type::Enum(id), Type::Enum(fid)) = (value.ty, fn_result) else {
            unreachable!("both are enum instances")
        };
        let is_result = Some(tid) == result;
        if is_result && env.enum_args(id)[1] != env.enum_args(fid)[1] {
            return Err(err(
                span,
                format!(
                    "? no convierte errores: {} no es compatible con el retorno {}",
                    env.type_name(value.ty),
                    env.type_name(fn_result)
                ),
            ));
        }
        let (ok, fail) = if is_result {
            ("Ok", "Err")
        } else {
            ("Some", "None")
        };
        let ok = env.variant_index(tid, ok).expect("prelude variant");
        let fail = env.variant_index(tid, fail).expect("prelude variant");
        let payload_ty = env.payload(id, ok)[0];
        let x = self.fresh();
        let mut fail_bindings = Vec::new();
        let mut fail_sub = Vec::new();
        let mut fail_payload = Vec::new();
        if is_result {
            let e = self.fresh();
            let ety = env.payload(id, fail)[0];
            fail_bindings.push((e, ety));
            fail_sub.push(Pattern::Bind(e));
            fail_payload.push(Value {
                ty: ety,
                span,
                kind: ValueKind::Local(e),
            });
        }
        let early = Value {
            ty: fn_result,
            span,
            kind: ValueKind::Variant(fid, fail, fail_payload),
        };
        let arms = vec![
            Arm {
                pattern: Pattern::Variant(id, ok, vec![Pattern::Bind(x)]),
                bindings: vec![(x, payload_ty)],
                body: Vec::new(),
                value: Some(Value {
                    ty: payload_ty,
                    span,
                    kind: ValueKind::Local(x),
                }),
                diverges: false,
            },
            Arm {
                pattern: Pattern::Variant(id, fail, fail_sub),
                bindings: fail_bindings,
                body: vec![Instruction::Return(early)],
                value: None,
                diverges: true,
            },
        ];
        Ok((payload_ty, ValueKind::Match(Box::new(value), arms)))
    }
    /// `a ?? b`: payload of `a` when `Some`, otherwise `b` (evaluated only then).
    fn coalesce(
        &mut self,
        a: &parser::Expr,
        b: &parser::Expr,
        span: Span,
        depth: usize,
        expected: Option<Type>,
    ) -> Result<(Type, ValueKind), Diagnostic> {
        let env = self.env;
        let option = env
            .prelude_template("Option")
            .ok_or_else(|| err(span, "prelude sin Option"))?;
        let hint = match expected {
            Some(t) => Some(Type::Enum(env.instantiate(option, vec![t], span)?)),
            None => None,
        };
        let a = self.expr(a, depth + 1, hint)?;
        let Type::Enum(id) = a.ty else {
            return Err(err(
                span,
                format!(
                    "?? requiere Option a la izquierda, encontrado {}",
                    env.type_name(a.ty)
                ),
            ));
        };
        if env.template_of(a.ty) != Some(option) {
            return Err(err(
                span,
                format!(
                    "?? requiere Option a la izquierda, encontrado {}",
                    env.type_name(a.ty)
                ),
            ));
        }
        let some = env.variant_index(option, "Some").expect("prelude variant");
        let none = env.variant_index(option, "None").expect("prelude variant");
        let t = env.payload(id, some)[0];
        let b = self.expr(b, depth + 1, Some(t))?;
        env.same(t, b.ty, b.span)?;
        let x = self.fresh();
        let arms = vec![
            Arm {
                pattern: Pattern::Variant(id, some, vec![Pattern::Bind(x)]),
                bindings: vec![(x, t)],
                body: Vec::new(),
                value: Some(Value {
                    ty: t,
                    span,
                    kind: ValueKind::Local(x),
                }),
                diverges: false,
            },
            Arm {
                pattern: Pattern::Variant(id, none, Vec::new()),
                bindings: Vec::new(),
                body: Vec::new(),
                value: Some(b),
                diverges: false,
            },
        ];
        Ok((t, ValueKind::Match(Box::new(a), arms)))
    }
    fn block(
        &mut self,
        stmts: &[Stmt],
        nested: bool,
        tail: bool,
    ) -> Result<(Vec<Instruction>, bool), Diagnostic> {
        if nested {
            self.push_scope();
        }
        let result = self.block_inner(stmts, tail);
        if nested {
            self.pop_scope();
        }
        result
    }
    /// Lowers statements. The flag is true when control never reaches the end of
    /// the block normally (return, break, continue or divergence on every path).
    fn block_inner(
        &mut self,
        stmts: &[Stmt],
        tail: bool,
    ) -> Result<(Vec<Instruction>, bool), Diagnostic> {
        let env = self.env;
        let mut out = Vec::new();
        let mut returns = false;
        for (index, stmt) in stmts.iter().enumerate() {
            let last = tail && index + 1 == stmts.len();
            let instruction = match stmt {
                Stmt::Const(c) => {
                    let annotation = match &c.annotation {
                        Some(t) => Some(env.resolve(t, self.owner, &[])?),
                        None => None,
                    };
                    let v = self.expr(&c.value, 0, annotation)?;
                    if let Some(t) = annotation {
                        env.same(t, v.ty, c.span)?;
                    }
                    let v = crate::consteval::evaluate(&v)?;
                    self.bind(&c.name, v.ty, false, c.span)?;
                    if let Some(binding) = self.scopes.last_mut().and_then(|s| s.get_mut(&c.name)) {
                        binding.constant = Some(v);
                    }
                    // Constants are substituted as values; no runtime instruction.
                    continue;
                }
                Stmt::Let(n, mutable, annotation, e) if matches!(&e.kind, ExprKind::Unary(op, _) if op == "&" || op == "&mut") =>
                {
                    let ExprKind::Unary(op, target) = &e.kind else {
                        unreachable!()
                    };
                    if *mutable || !named_place(target) {
                        return Err(err(e.span, "use let para prestar una variable, campo o elemento con un origen fijo").classify("L0012", "préstamos"));
                    }
                    let source = self.lookup(&root_name(target), target.span)?;
                    if source.constant.is_some() || matches!(source.ty, Type::Region(_)) {
                        return Err(err(
                            e.span,
                            "el préstamo requiere un lugar de datos en memoria",
                        )
                        .classify("L0012", "préstamos"));
                    }
                    if matches!(
                        source.ty,
                        Type::TaskGroup(_) | Type::Future(_) | Type::Task(_)
                    ) {
                        let name = match source.ty {
                            Type::TaskGroup(_) => "TaskGroup",
                            Type::Future(_) => "Future",
                            _ => "TaskHandle",
                        };
                        return Err(
                            err(e.span, format!("{name} no admite préstamos (& o &mut)"))
                                .classify("L0012", "préstamos"),
                        );
                    }
                    let mode = if op == "&mut" {
                        Receiver::Exclusive
                    } else {
                        Receiver::Shared
                    };
                    if mode == Receiver::Exclusive
                        && (!source.mutable || source.ref_mode == Some(Receiver::Shared))
                    {
                        return Err(err(
                            e.span,
                            "no se puede prestar mutablemente una variable inmutable",
                        )
                        .classify("L0012", "préstamos"));
                    }
                    let value = self.expr(target, 0, None)?;
                    if !addressable(&value) {
                        return Err(err(
                            e.span,
                            "el préstamo requiere un lugar de datos, no una propiedad calculada",
                        )
                        .classify("L0012", "préstamos"));
                    }
                    let mut referent = value.ty;
                    if let Some(annotation) = annotation {
                        let (ty, declared) =
                            env.resolve_param(annotation, self.owner, &self.bindings)?;
                        if declared != Some(mode) {
                            return Err(err(
                                e.span,
                                "la anotación debe coincidir con el modo & o &mut del préstamo",
                            )
                            .classify("L0012", "préstamos"));
                        }
                        let slice_view = matches!(ty, Type::Slice(_))
                            && env.elem_of(ty) == env.elem_of(value.ty);
                        let regional_bytes = ty == Type::Bytes(crate::lir::CALLER_REGION)
                            && matches!(value.ty, Type::Bytes(_));
                        if !slice_view && !regional_bytes {
                            env.same(ty, value.ty, e.span)?;
                        }
                        if !regional_bytes {
                            referent = ty;
                        }
                    }
                    let id = self.bind_ref(
                        n,
                        referent,
                        mode == Receiver::Exclusive,
                        Some(mode),
                        e.span,
                    )?;
                    Instruction::BindRef(id, mode, referent, value)
                }
                Stmt::Let(n, mutable, annotation, e) => {
                    let (annotation, declared_mode) = match annotation {
                        Some(TypeExpr::Named(name, args, span)) if name == "TaskGroup" => {
                            if !self.is_async {
                                return Err(async_error(
                                    *span,
                                    "TaskGroup requiere un ámbito async",
                                ));
                            }
                            if args.len() != 1 {
                                return Err(err(
                                    *span,
                                    "TaskGroup requiere 1 argumento de tipo: TaskGroup<T>",
                                ));
                            }
                            let elem = env.resolve(&args[0], self.owner, &self.bindings)?;
                            let ty = env.task_group_ty(elem, self.current_scope(), *span)?;
                            (Some(ty), None)
                        }
                        Some(TypeExpr::Named(name, args, _))
                            if args.is_empty()
                                && env
                                    .struct_ids
                                    .get(name)
                                    .is_some_and(|id| env.is_view(Type::Struct(*id))) =>
                        {
                            (Some(Type::Struct(env.struct_ids[name])), None)
                        }
                        Some(t) => {
                            let (ty, mode) = env.resolve_param(t, self.owner, &self.bindings)?;
                            (Some(ty), mode)
                        }
                        None => (None, None),
                    };
                    self.ref_result_allowed = true;
                    self.view_use = ViewUse::Initialize;
                    let v = self.expr(e, 0, annotation)?;
                    if let Some(t) = annotation {
                        env.same(t, v.ty, v.span)?;
                    }
                    if let Some(contract) = self.call_return(&v.kind) {
                        if *mutable
                            || declared_mode.is_some_and(|mode| mode != contract.mode)
                            || (annotation.is_some() && declared_mode.is_none())
                        {
                            return Err(lifetime(
                                e.span,
                                "el resultado prestado requiere let y una anotación de referencia compatible",
                            ));
                        }
                        let id = self.bind_ref(
                            n,
                            v.ty,
                            contract.mode == Receiver::Exclusive,
                            Some(contract.mode),
                            e.span,
                        )?;
                        Instruction::BindRef(id, contract.mode, v.ty, v)
                    } else {
                        if declared_mode.is_some() {
                            return Err(lifetime(
                                e.span,
                                "la anotación de referencia requiere un préstamo o una llamada que lo devuelva",
                            ));
                        }
                        let bind_ty = annotation.unwrap_or(v.ty);
                        let id = self.bind(n, bind_ty, *mutable, e.span)?;
                        Instruction::Bind(id, *mutable, v)
                    }
                }
                Stmt::Assign(target, op, e, span) => self.assign(target, op, e, *span)?,
                Stmt::Return(e) if self.borrow_return.is_some() => {
                    returns = true;
                    self.returning_reference(e, self.borrow_return.as_ref().unwrap().mode)?
                }
                Stmt::Expr(e, false) if last && self.borrow_return.is_some() => {
                    returns = true;
                    self.returning_reference(e, self.borrow_return.as_ref().unwrap().mode)?
                }
                Stmt::Return(e) => {
                    if matches!(&e.kind, ExprKind::Unary(op, _) if op == "&" || op == "&mut") {
                        return Err(err(
                            e.span,
                            "no se puede devolver una referencia a una variable local que deja de existir (devolver referencias requiere anotaciones de vida aún no implementadas)",
                        ));
                    }
                    if self.view_return.is_some() {
                        self.view_use = ViewUse::Initialize;
                    }
                    let v = self.expr(e, 0, self.result)?;
                    if matches!(v.ty, Type::TaskGroup(_)) {
                        return Err(async_error(
                            v.span,
                            "un grupo de tareas no se puede retornar fuera de su función creadora",
                        ));
                    }
                    self.check_return_borrow(&v)?;
                    self.set_result(v.ty, v.span)?;
                    returns = true;
                    Instruction::Return(v)
                }
                Stmt::Expr(e, explicit) => {
                    let value_position = last && !explicit;
                    if value_position && self.view_return.is_some() {
                        self.view_use = ViewUse::Initialize;
                    }
                    let v = match &e.kind {
                        ExprKind::Match(s, arms) if !value_position => {
                            self.match_expr(s, arms, e.span, 0, None, true)?
                        }
                        _ => self.expr(e, 0, if value_position { self.result } else { None })?,
                    };
                    if diverges(&v) {
                        returns = true;
                        Instruction::Eval(v)
                    } else if value_position {
                        if matches!(v.ty, Type::TaskGroup(_)) {
                            return Err(async_error(
                                v.span,
                                "un grupo de tareas no se puede retornar fuera de su función creadora",
                            ));
                        }
                        self.check_return_borrow(&v)?;
                        self.set_result(v.ty, v.span)?;
                        returns = true;
                        Instruction::Return(v)
                    } else {
                        Instruction::Eval(v)
                    }
                }
                Stmt::If(e, yes, no, explicit) => {
                    let v = self.expr(e, 0, Some(Type::Bool))?;
                    env.same(Type::Bool, v.ty, v.span)?;
                    let (yes, yr) = self.block(yes, true, last && !explicit)?;
                    let (no, nr) = self.block(no, true, last && !explicit)?;
                    returns |= yr && nr;
                    Instruction::If(v, yes, no)
                }
                Stmt::While(e, body) => {
                    let v = self.expr(e, 0, Some(Type::Bool))?;
                    env.same(Type::Bool, v.ty, v.span)?;
                    self.loop_depth += 1;
                    let body = self.block(body, true, false);
                    self.loop_depth -= 1;
                    Instruction::While(v, body?.0)
                }
                Stmt::For(name, span, start, end, inclusive, body) => {
                    let start = self.expr(start, 0, Some(Type::Int))?;
                    env.same(Type::Int, start.ty, start.span)?;
                    let end = self.expr(end, 0, Some(Type::Int))?;
                    env.same(Type::Int, end.ty, end.span)?;
                    self.push_scope();
                    let id = self.bind(name, Type::Int, false, *span);
                    self.loop_depth += 1;
                    let body = id.and_then(|id| Ok((id, self.block(body, true, false)?)));
                    self.loop_depth -= 1;
                    self.pop_scope();
                    let (id, (body, _)) = body?;
                    Instruction::ForRange(id, start, end, *inclusive, body)
                }
                Stmt::ForEach(name, span, coll, body) => {
                    let coll = match &coll.kind {
                        // `for x in &c` borrows exactly like `for x in c`.
                        ExprKind::Unary(op, inner) if op == "&" => inner.as_ref(),
                        ExprKind::Unary(op, _) if op == "&mut" => {
                            return Err(err(
                                coll.span,
                                "feature not implemented: iteración mutable (for x in &mut c); modifique con c[i] = v",
                            ));
                        }
                        _ => coll,
                    };
                    self.view_use = ViewUse::FieldBase;
                    let coll = self.expr(coll, 0, None)?;
                    let Some(elem) = env.elem_of(coll.ty) else {
                        return Err(err(
                            coll.span,
                            format!(
                                "for x in ... requiere un array, slice o List, no {}",
                                env.type_name(coll.ty)
                            ),
                        ));
                    };
                    // Copy elements are copied; owned elements are borrowed:
                    // iterating never consumes the collection.
                    let by_ref = elem.is_move();
                    let (bound_ty, is_mut, ref_mode) = match elem {
                        Type::SharedField(target) => {
                            (target.referent(), false, Some(Receiver::Shared))
                        }
                        Type::MutField(target) => {
                            (target.referent(), true, Some(Receiver::Exclusive))
                        }
                        _ => (
                            elem,
                            false,
                            if by_ref { Some(Receiver::Shared) } else { None },
                        ),
                    };
                    self.push_scope();
                    let id = self.bind_ref(name, bound_ty, is_mut, ref_mode, *span);
                    self.loop_depth += 1;
                    let body = id.and_then(|id| Ok((id, self.block(body, true, false)?)));
                    self.loop_depth -= 1;
                    self.pop_scope();
                    let (id, (body, _)) = body?;
                    Instruction::ForEach(id, by_ref, coll, body)
                }
                Stmt::Loop(body) => {
                    self.loop_depth += 1;
                    let lowered = self.block(body, true, false);
                    self.loop_depth -= 1;
                    // A `loop` without a `break` of its own never completes normally.
                    returns |= !breaks(body);
                    Instruction::Loop(lowered?.0)
                }
                Stmt::Break(span) | Stmt::Continue(span) => {
                    if self.loop_depth == 0 {
                        return Err(err(*span, "break/continue fuera de un bucle"));
                    }
                    returns = true;
                    if matches!(stmt, Stmt::Break(_)) {
                        Instruction::Break
                    } else {
                        Instruction::Continue
                    }
                }
                Stmt::Block(body, explicit) => {
                    let (body, ret) = self.block(body, true, last && !explicit)?;
                    returns |= ret;
                    Instruction::Block(body)
                }
                Stmt::Region(name, span, body) => {
                    // The region binding and the body share one scope; at
                    // its end the body's locals are dropped first, then the
                    // region releases its storage.
                    let rid = {
                        let mut regions = env.regions.borrow_mut();
                        regions.push(name.clone());
                        regions.len() - 1
                    };
                    self.push_scope();
                    let id = self.bind(name, Type::Region(rid), false, *span);
                    let inner = id.and_then(|id| Ok((id, self.block(body, true, last)?)));
                    self.pop_scope();
                    let (id, (body, ret)) = inner?;
                    returns |= ret;
                    Instruction::Block(vec![
                        Instruction::Bind(
                            id,
                            false,
                            Value {
                                ty: Type::Region(rid),
                                span: *span,
                                kind: ValueKind::RegionNew,
                            },
                        ),
                        Instruction::Block(body),
                    ])
                }
            };
            out.push(instruction);
        }
        Ok((out, returns))
    }
    /// `c[i] = v`, `c[i] op= v` or `c[i].campo = v`.
    fn store_elem(
        &mut self,
        target: &parser::Expr,
        op: &str,
        e: &parser::Expr,
        span: Span,
    ) -> Result<Instruction, Diagnostic> {
        let env = self.env;
        let root = root_name(target);
        let binding = self.lookup(&root, span)?;
        if binding.ref_mode == Some(Receiver::Shared) {
            return Err(err(
                span,
                format!("no se puede modificar a través de una referencia de lectura: {root}"),
            ));
        }
        if !binding.mutable && binding.ref_mode != Some(Receiver::Exclusive) {
            return Err(err(
                span,
                format!(
                    "asignación a un elemento de un binding inmutable (declárelo con var o use &mut): {root}"
                ),
            ));
        }
        // The value is evaluated first, then the place (and its index).
        let mut v = self.stored_expr(e, 0, None)?;
        let place = self.expr(target, 0, None)?;
        env.same(place.ty, v.ty, v.span)?;
        if op != "=" {
            let operator = &op[..1];
            let result = binary_type(env, operator, &place, &v)?;
            v = Value {
                ty: result,
                span,
                kind: ValueKind::Binary(operator.into(), Box::new(place.clone()), Box::new(v)),
            };
        }
        Ok(Instruction::StoreElem(place, v))
    }
    fn assign(
        &mut self,
        target: &parser::Expr,
        op: &str,
        e: &parser::Expr,
        span: Span,
    ) -> Result<Instruction, Diagnostic> {
        let env = self.env;
        if matches!(&target.kind, ExprKind::Name(n) if n == "self") {
            return Err(err(
                span,
                "no se puede reasignar self completo; modifique sus campos",
            ));
        }
        if has_index(target) {
            return self.store_elem(target, op, e, span);
        }
        let (place, binding, ty) = match self.place(target) {
            Some(result) => result?,
            None => {
                return Err(err(
                    span,
                    format!(
                        "reasignación prohibida de binding inmutable: {}",
                        root_name(target)
                    ),
                ));
            }
        };
        if binding.ref_mode == Some(Receiver::Shared) {
            return Err(err(
                span,
                format!(
                    "no se puede mutar a través de una referencia inmutable &T (binding inmutable): {}",
                    root_name(target)
                ),
            ));
        }
        let mut current_ty = binding.ty;
        let mut last_field_ty = None;
        for &f in &place.fields {
            if let Type::Struct(sid) = current_ty {
                let fty = self.env.structs.borrow()[sid].fields[f].1;
                last_field_ty = Some(fty);
                current_ty = match fty {
                    Type::SharedField(t) | Type::MutField(t) => t.referent(),
                    _ => fty,
                };
            }
        }
        if let Some(Type::SharedField(_)) = last_field_ty {
            return Err(err(
                span,
                format!(
                    "no se puede mutar a través de una referencia inmutable &T (binding inmutable): {}",
                    root_name(target)
                ),
            ));
        }
        if !binding.mutable {
            let what = if place.fields.is_empty() {
                "reasignación prohibida de binding inmutable"
            } else {
                "asignación a campo de binding inmutable (declárelo con var o use mut fn)"
            };
            return Err(err(span, format!("{what}: {}", root_name(target))));
        }
        let mut v = if place.fields.is_empty() {
            if env.is_view(ty) {
                self.view_use = ViewUse::Initialize;
            }
            let res = self.expr(e, 0, Some(ty))?;
            self.view_use = ViewUse::None;
            res
        } else {
            self.stored_expr(e, 0, Some(ty))?
        };
        env.same(ty, v.ty, v.span)?;
        if let (Type::TaskGroup(_), Type::TaskGroup(rhs_g)) = (ty, v.ty) {
            let lhs_scope = binding.scope;
            let rhs_scope = env.task_groups.borrow()[rhs_g].scope;
            if rhs_scope != lhs_scope && env.is_subscope_of(rhs_scope, lhs_scope) {
                return Err(err(
                    span,
                    "el grupo de tareas no puede escapar a un ámbito más amplio",
                )
                .classify("L0015", "concurrencia"));
            }
        }
        if op != "=" {
            let lhs = self.expr(target, 0, None)?;
            let operator = &op[..1];
            let result = binary_type(env, operator, &lhs, &v)?;
            v = Value {
                ty: result,
                span,
                kind: ValueKind::Binary(operator.into(), Box::new(lhs), Box::new(v)),
            };
        }
        Ok(Instruction::Store(place, v))
    }
}

/// Types with a textual form for print and interpolation.
fn printable(t: Type) -> bool {
    match t {
        Type::Int | Type::Float | Type::F32 | Type::Bool | Type::Text => true,
        Type::SharedField(target) | Type::MutField(target) => printable(target.referent()),
        _ => false,
    }
}

fn has_index(e: &parser::Expr) -> bool {
    match &e.kind {
        ExprKind::Index(..) => true,
        ExprKind::Field(base, _) => has_index(base),
        _ => false,
    }
}

/// A constant index is checked at compile time: negative is always an error,
/// and so is one past the end of a fixed-size array.
fn check_constant_index(env: &Env, base: &Value, index: &Value) -> Result<(), Diagnostic> {
    let n = match &index.kind {
        ValueKind::Int(n) => *n,
        ValueKind::Unary(op, inner) if op == "-" => match inner.kind {
            ValueKind::Int(n) => -n,
            _ => return Ok(()),
        },
        _ => return Ok(()),
    };
    if n < 0 {
        return Err(err(index.span, format!("índice constante negativo: {n}")));
    }
    if let Type::Array(a) = base.ty {
        let len = env.arrays.borrow()[a].len;
        if n as usize >= len {
            return Err(err(
                index.span,
                format!(
                    "índice constante {n} fuera de rango para {} (longitud {len})",
                    env.type_name(base.ty)
                ),
            ));
        }
    }
    Ok(())
}

/// Whether `e` is an element of a collection (or a field of one).
fn element_place(e: &parser::Expr) -> bool {
    match &e.kind {
        ExprKind::Index(base, _) => named_place(base),
        ExprKind::Field(base, _) => element_place(base),
        _ => false,
    }
}

/// A chain of fields and indices rooted at a variable.
fn named_place(e: &parser::Expr) -> bool {
    match &e.kind {
        ExprKind::Name(_) => true,
        ExprKind::Field(base, _) | ExprKind::Index(base, _) => named_place(base),
        _ => false,
    }
}

fn addressable(value: &Value) -> bool {
    match &value.kind {
        ValueKind::Local(_) => true,
        ValueKind::Field(base, _) | ValueKind::Index(base, _) => addressable(base),
        _ => false,
    }
}

fn root_name(e: &parser::Expr) -> String {
    match &e.kind {
        ExprKind::Name(n) => n.clone(),
        ExprKind::Field(base, _) | ExprKind::Index(base, _) => root_name(base),
        _ => "destino".into(),
    }
}

/// True if `body` contains a `break` that targets the enclosing loop (nested
/// loops capture their own breaks).
fn breaks(body: &[Stmt]) -> bool {
    fn expr_breaks(e: &parser::Expr) -> bool {
        match &e.kind {
            ExprKind::Match(s, arms) => expr_breaks(s) || arms.iter().any(|a| breaks(&a.body)),
            _ => false,
        }
    }
    body.iter().any(|s| match s {
        Stmt::Break(_) => true,
        Stmt::If(_, yes, no, _) => breaks(yes) || breaks(no),
        Stmt::Block(b, _) => breaks(b),
        Stmt::Expr(e, _) => expr_breaks(e),
        _ => false,
    })
}
fn numeric(t: Type) -> bool {
    matches!(t, Type::Int | Type::Float | Type::F32)
}
fn binary_type(env: &Env, op: &str, a: &Value, b: &Value) -> Result<Type, Diagnostic> {
    env.same(a.ty, b.ty, b.span)?;
    if a.ty.is_region_bound()
        || matches!(
            a.ty,
            Type::Array(_) | Type::Slice(_) | Type::List(_) | Type::RegionList(..)
        )
    {
        return Err(err(
            a.span,
            format!("operador {op} no definido sobre {}", env.type_name(a.ty)),
        ));
    }
    if a.ty == Type::Text {
        return Err(err(
            a.span,
            "feature not implemented: operadores sobre Text",
        ));
    }
    if let Type::Struct(_) | Type::Enum(_) = a.ty {
        return Err(err(
            a.span,
            format!(
                "feature not implemented: operador {op} sobre {} {}; use match",
                if matches!(a.ty, Type::Enum(_)) {
                    "enum"
                } else {
                    "struct"
                },
                env.type_name(a.ty)
            ),
        ));
    }
    match op {
        "+" | "-" | "*" | "/" | "%" if numeric(a.ty) => Ok(a.ty),
        "<" | "<=" | ">" | ">=" if numeric(a.ty) => Ok(Type::Bool),
        "==" | "!=" => Ok(Type::Bool),
        "&&" | "||" if a.ty == Type::Bool => Ok(Type::Bool),
        _ => Err(err(
            a.span,
            format!("operador {op} incompatible con {}", env.type_name(a.ty)),
        )),
    }
}

const RESERVED_TYPES: [&str; 10] = [
    "Int",
    "Float",
    "f64",
    "f32",
    "Bool",
    "Text",
    "Self",
    "print",
    "TaskGroup",
    "Future",
];

/// Every function body to lower, with the type that owns it (methods).
type Decls<'a> = Vec<(&'a parser::Function, Option<Type>)>;

fn prelude() -> parser::Program {
    let tokens = crate::lexer::lex(PRELUDE).expect("prelude lexes");
    parser::parse(tokens).expect("prelude parses")
}

/// Collects type names, struct fields, enum templates and every function
/// signature. Defaults are evaluated later, once global constants are known.
fn declare<'a>(
    program: &'a parser::Program,
    prelude: &'a parser::Program,
) -> Result<(Env, Decls<'a>), Diagnostic> {
    let mut direct_imports: HashMap<u32, HashSet<u32>> = HashMap::new();
    for import in &program.imports {
        if let Some(target_file) = import.target_file {
            direct_imports
                .entry(import.span.file)
                .or_default()
                .insert(target_file);
        }
    }
    let env = Env {
        structs: RefCell::new(Vec::new()),
        join_pairs: RefCell::new(HashMap::new()),
        struct_ids: HashMap::new(),
        struct_templates: Vec::new(),
        struct_template_ids: HashMap::new(),
        struct_instances: RefCell::new(HashMap::new()),
        struct_args: RefCell::new(HashMap::new()),
        struct_template_of: RefCell::new(HashMap::new()),
        instantiating_structs: RefCell::new(Vec::new()),
        templates: Vec::new(),
        template_ids: HashMap::new(),
        enums: RefCell::new(Vec::new()),
        enum_ids: RefCell::new(HashMap::new()),
        instantiating: RefCell::new(Vec::new()),
        unqualified: HashMap::new(),
        regions: RefCell::new(Vec::new()),
        arrays: RefCell::new(Vec::new()),
        slices: RefCell::new(Vec::new()),
        lists: RefCell::new(Vec::new()),
        task_groups: RefCell::new(Vec::new()),
        task_group_ids: RefCell::new(HashMap::new()),
        next_scope_id: Cell::new(1),
        scope_parents: RefCell::new(HashMap::new()),
        futures: RefCell::new(Vec::new()),
        traits: Vec::new(),
        trait_ids: HashMap::new(),
        trait_impls: RefCell::new(HashMap::new()),
        generic_trait_impls: Vec::new(),
        functions: RefCell::new(HashMap::new()),
        module_functions: RefCell::new(HashMap::new()),
        direct_imports,
        public_functions: RefCell::new(HashSet::new()),
        ambiguous_private_functions: RefCell::new(HashSet::new()),
        methods: RefCell::new(HashMap::new()),
        sigs: RefCell::new(Vec::new()),
        fn_templates: Vec::new(),
        fn_template_ids: HashMap::new(),
        module_fn_templates: HashMap::new(),
        public_fn_templates: HashSet::new(),
        ambiguous_private_fn_templates: HashSet::new(),
        fn_instances: RefCell::new(HashMap::new()),
        instantiating_fns: RefCell::new(Vec::new()),
        method_templates: Vec::new(),
        queued_fns: RefCell::new(Vec::new()),
        fn_contracts: RefCell::new(HashMap::new()),
        trait_contracts: Vec::new(),
        impl_methods: RefCell::new(HashMap::new()),
    };
    let mut env = env;
    let taken = |env: &Env, name: &str| {
        PlatformOp::named(name).is_some()
            || matches!(name, JOIN | JOIN_ALL | TASK_GROUP | SLEEP_MS)
            || RESERVED_TYPES.contains(&name)
            || env.struct_ids.contains_key(name)
            || env.struct_template_ids.contains_key(name)
            || env.template_ids.contains_key(name)
            || env.trait_ids.contains_key(name)
            || env.unqualified.contains_key(name)
    };
    for (decls, is_prelude) in [(&prelude.enums, true), (&program.enums, false)] {
        for e in decls {
            if taken(&env, &e.name) {
                return Err(err(
                    e.span,
                    format!("enum duplicado o reservado: {}", e.name),
                ));
            }
            let mut names = HashSet::new();
            for v in &e.variants {
                if !names.insert(v.name.as_str()) {
                    return Err(err(
                        v.span,
                        format!("variante duplicada en {}: {}", e.name, v.name),
                    ));
                }
            }
            let mut params = HashSet::new();
            for p in &e.params {
                if !params.insert(p) || RESERVED_TYPES.contains(&p.as_str()) {
                    return Err(err(
                        e.span,
                        format!("parámetro de tipo duplicado o reservado: {p}"),
                    ));
                }
            }
            let tid = env.templates.len();
            env.template_ids.insert(e.name.clone(), tid);
            env.templates.push(EnumTemplate {
                name: e.name.clone(),
                params: e.params.clone(),
                variants: e
                    .variants
                    .iter()
                    .map(|v| (v.name.clone(), v.payload.clone()))
                    .collect(),
                prelude: is_prelude,
            });
            if is_prelude {
                for (i, v) in e.variants.iter().enumerate() {
                    env.unqualified.insert(v.name.clone(), (tid, i));
                }
            }
        }
    }
    for tr in &program.traits {
        if taken(&env, &tr.name) {
            return Err(err(
                tr.span,
                format!("trait duplicado o reservado: {}", tr.name),
            ));
        }
        let tid = env.traits.len();
        env.trait_ids.insert(tr.name.clone(), tid);
        let mut method_names = HashSet::new();
        for m in &tr.methods {
            if !method_names.insert(m.name.as_str()) {
                return Err(err(
                    m.span,
                    format!("método duplicado en trait {}: {}", tr.name, m.name),
                ));
            }
            let noalloc = m
                .attributes
                .iter()
                .any(|a| matches!(a, Attribute::NoAlloc(_)));
            let allowed = m.effects.map(|e| e.allowed).unwrap_or(if noalloc {
                let mut s = EffectSet::ALL;
                s.alloc = false;
                s
            } else {
                EffectSet::ALL
            });
            if m.effects.is_some() || noalloc {
                env.trait_contracts.push(TraitMethodContract {
                    trait_name: tr.name.clone(),
                    method_name: m.name.clone(),
                    allowed,
                    noalloc,
                    span: m.span,
                });
            }
        }
        env.traits.push(TraitInfo {
            name: tr.name.clone(),
            params: tr.params.clone(),
            methods: tr.methods.clone(),
            span: tr.span,
        });
    }
    for s in &program.structs {
        if taken(&env, &s.name) {
            return Err(err(
                s.span,
                format!("struct duplicado o reservado: {}", s.name),
            ));
        }
        if s.params.is_empty() {
            let sid = env.structs.borrow().len();
            env.struct_ids.insert(s.name.clone(), sid);
            env.structs.borrow_mut().push(StructInfo {
                local_view: s.fields.iter().any(|f| matches!(f.ty, TypeExpr::Ref(..))),
                name: s.name.clone(),
                fields: Vec::new(),
                defaults: Vec::new(),
            });
        } else {
            let tid = env.struct_templates.len();
            env.struct_template_ids.insert(s.name.clone(), tid);
            env.struct_templates.push(StructTemplate {
                name: s.name.clone(),
                params: s.params.clone(),
                fields: s.fields.clone(),
                span: s.span,
            });
        }
    }
    // Validate every enum template by instantiating payloads with its own parameters
    // left abstract: non-generic enums are instantiated now.
    for e in &program.enums {
        let tid = env.template_ids[&e.name];
        if e.params.is_empty() {
            env.instantiate(tid, Vec::new(), e.span)?;
        } else {
            for v in &e.variants {
                for t in &v.payload {
                    check_template_type(&env, t, &e.params)?;
                }
            }
        }
    }
    for s in &program.structs {
        if s.params.is_empty() {
            let sid = env.struct_ids[&s.name];
            let mut names = HashSet::new();
            for f in &s.fields {
                if !names.insert(f.name.as_str()) {
                    return Err(err(
                        f.span,
                        format!("campo duplicado en {}: {}", s.name, f.name),
                    ));
                }
                let ty = match &f.ty {
                    TypeExpr::Ref(inner, false, span) => {
                        if f.default.is_some() {
                            return Err(aggregate_escape(*span));
                        }
                        let ty = env.resolve(inner, None, &[])?;
                        Type::SharedField(crate::lir::SharedTarget::from_type(ty).ok_or_else(
                            || {
                                err(
                                    *span,
                                    "los campos prestados locales solo admiten escalares y Text",
                                )
                                .classify("L0014", "préstamos")
                            },
                        )?)
                    }
                    TypeExpr::Ref(inner, true, span) => {
                        if f.default.is_some() {
                            return Err(aggregate_escape(*span));
                        }
                        let ty = env.resolve(inner, None, &[])?;
                        Type::MutField(crate::lir::SharedTarget::from_type(ty).ok_or_else(
                            || {
                                err(
                                    *span,
                                    "los campos prestados locales solo admiten escalares y Text",
                                )
                                .classify("L0014", "préstamos")
                            },
                        )?)
                    }
                    _ => env.resolve(&f.ty, Some(Type::Struct(sid)), &[])?,
                };
                if matches!(ty, Type::Future(_)) {
                    return Err(err(
                        f.span,
                        "Future no se puede almacenar en un agregado ni colecciones",
                    )
                    .classify("L0015", "concurrencia"));
                }
                if ty == Type::Unit {
                    return Err(err(f.span, "un campo no puede ser de tipo ()"));
                }
                if env.is_view(ty) {
                    return Err(view_escape(f.span));
                }
                env.structs.borrow_mut()[sid]
                    .fields
                    .push((f.name.clone(), ty));
            }
        } else {
            let p_names: Vec<String> = s.params.iter().map(|p| p.name.clone()).collect();
            let mut names = HashSet::new();
            for f in &s.fields {
                if !names.insert(f.name.as_str()) {
                    return Err(err(
                        f.span,
                        format!("campo duplicado en {}: {}", s.name, f.name),
                    ));
                }
                check_template_type(&env, &f.ty, &p_names)?;
            }
        }
    }
    reject_recursive_types(&env, program)?;

    let mut decls: Decls<'a> = Vec::new();
    for f in &program.functions {
        if f.name == "print" || f.name == YIELD_NOW || taken(&env, &f.name) {
            return Err(err(
                f.span,
                format!("función duplicada o reservada: {}", f.name),
            ));
        }
        if !f.type_params.is_empty() {
            let tid = env.fn_templates.len();
            // A private generic can share its spelling with one in another
            // module. Repeated declarations within a module remain errors.
            if env
                .module_fn_templates
                .insert((f.span.file, f.name.clone()), tid)
                .is_some()
            {
                return Err(err(
                    f.span,
                    format!("función duplicada o reservada: {}", f.name),
                ));
            }
            let previous = env.fn_template_ids.get(&f.name).copied();
            if f.public || f.span.file == 0 {
                if f.span.file == 0 && previous.is_some() {
                    return Err(err(
                        f.span,
                        format!("función duplicada o reservada: {}", f.name),
                    ));
                }
                if f.public {
                    env.public_fn_templates.insert(tid);
                }
                env.fn_template_ids.insert(f.name.clone(), tid);
            } else if !env.ambiguous_private_fn_templates.contains(&f.name) {
                match previous {
                    Some(id) if env.public_fn_templates.contains(&id) => {
                        // The private template remains visible in its source.
                    }
                    Some(_) => {
                        env.fn_template_ids.remove(&f.name);
                        env.ambiguous_private_fn_templates.insert(f.name.clone());
                    }
                    None => {
                        env.fn_template_ids.insert(f.name.clone(), tid);
                    }
                }
            }
            let p_names: Vec<String> = f.type_params.iter().map(|p| p.name.clone()).collect();
            for tp in &f.type_params {
                if let Some(bound) = &tp.bound
                    && !env.trait_ids.contains_key(bound)
                {
                    return Err(err(tp.span, format!("trait no definido: {bound}")));
                }
            }
            for (_, t, _) in &f.params {
                check_template_signature_type(&env, t, &p_names)?;
            }
            if let Some(t) = &f.result {
                check_template_signature_type(&env, t, &p_names)?;
            }
            if f.is_async {
                return Err(async_error(
                    f.span,
                    "feature not implemented: funciones async genéricas",
                ));
            }
            env.fn_templates.push(FnTemplate {
                func: f.clone(),
                owner: None,
            });
        } else {
            let fid = env.sigs.borrow().len();
            // A private name is unique within its module, not across files.
            // Keep unambiguous imports working while Stage 0's full module
            // visibility rules are migrated to match Stage 1.
            if env
                .module_functions
                .borrow_mut()
                .insert((f.span.file, f.name.clone()), fid)
                .is_some()
            {
                return Err(err(
                    f.span,
                    format!("función duplicada o reservada: {}", f.name),
                ));
            }
            let previous = env.functions.borrow().get(&f.name).copied();
            if f.public || f.span.file == 0 {
                if f.span.file == 0 && previous.is_some() {
                    return Err(err(
                        f.span,
                        format!("función duplicada o reservada: {}", f.name),
                    ));
                }
                if f.public {
                    env.public_functions.borrow_mut().insert(fid);
                }
                env.functions.borrow_mut().insert(f.name.clone(), fid);
            } else if !env.ambiguous_private_functions.borrow().contains(&f.name) {
                match previous {
                    Some(id) if env.public_functions.borrow().contains(&id) => {
                        // This private declaration is only visible in its module.
                    }
                    Some(_) => {
                        env.functions.borrow_mut().remove(&f.name);
                        env.ambiguous_private_functions
                            .borrow_mut()
                            .insert(f.name.clone());
                    }
                    None => {
                        env.functions.borrow_mut().insert(f.name.clone(), fid);
                    }
                }
            }
            let mut params = Vec::new();
            let mut param_modes = Vec::new();
            for ((pname, t, psp), _) in f.params.iter().zip(0..) {
                let (ty, mode) = env.resolve_param(t, None, &[])?;
                if env.is_view(ty) {
                    return Err(view_escape(f.span));
                }
                if f.is_async
                    && (mode.is_some()
                        || (!matches!(
                            ty,
                            Type::Int
                                | Type::Float
                                | Type::F32
                                | Type::Bool
                                | Type::Unit
                                | Type::Future(_)
                        ) && !env.async_owned(ty)))
                {
                    return Err(async_error(
                        *psp,
                        format!(
                            "parámetro {pname} de una función async: tipo o modo no admitido en el estado de la tarea ({})",
                            env.type_name(ty)
                        ),
                    ));
                }
                params.push(ty);
                param_modes.push(mode);
            }
            let (result, borrow_return, view_return) =
                env.borrow_result(f, None, &[], &param_modes)?;
            // An async function never infers its result: callers need its
            // future type before any body is checked.
            let (result, async_result) = if f.is_async {
                let inner = match &f.result {
                    Some(t) => env.resolve(t, None, &[])?,
                    None => Type::Unit,
                };
                if inner.is_region_bound() || env.is_view(inner) || matches!(inner, Type::Slice(_))
                {
                    return Err(async_error(
                        f.span,
                        format!(
                            "resultado {} no admitido en una función async",
                            env.type_name(inner)
                        ),
                    ));
                }
                (Some(env.future_ty(inner, fid, &f.name)), Some(inner))
            } else {
                (result, None)
            };
            env.sigs.borrow_mut().push(Sig {
                is_async: f.is_async,
                async_result,
                name: f.name.clone(),
                kind: f.kind,
                owner: None,
                params,
                param_modes,
                result,
                borrow_return,
                view_return,
            });
            let noalloc = get_noalloc(&f.attributes);
            env.fn_contracts.borrow_mut().insert(
                fid,
                FnContract {
                    name: f.name.clone(),
                    span: f.span,
                    explicit_effects: f.effects,
                    noalloc,
                },
            );
            env.queued_fns.borrow_mut().push(FnToCompile {
                id: fid,
                target: FnTarget::Ast(f.clone()),
            });
            decls.push((f, None));
        }
    }
    for imp in &program.impls {
        if imp.trait_name.is_some()
            && env
                .struct_ids
                .get(&imp.target)
                .is_some_and(|id| env.is_view(Type::Struct(*id)))
        {
            return Err(view_escape(imp.span));
        }
        if let Some(trait_name) = &imp.trait_name {
            let trait_id = *env
                .trait_ids
                .get(trait_name)
                .ok_or_else(|| err(imp.span, format!("trait no definido: {trait_name}")))?;
            if let Some(&stid) = env.struct_template_ids.get(&imp.target) {
                env.generic_trait_impls.push(GenericTraitImpl {
                    params: imp.params.clone(),
                    trait_id,
                    target_template: stid,
                    methods: imp.methods.clone(),
                    span: imp.span,
                });
            } else {
                let target_ty = if let Some(&sid) = env.struct_ids.get(&imp.target) {
                    Type::Struct(sid)
                } else if let Some(&tid) = env.template_ids.get(&imp.target) {
                    Type::Enum(env.instantiate(tid, Vec::new(), imp.span)?)
                } else {
                    match imp.target.as_str() {
                        "Int" => Type::Int,
                        "Float" | "f64" => Type::Float,
                        "f32" => Type::F32,
                        "Bool" => Type::Bool,
                        "Text" => Type::Text,
                        _ => {
                            return Err(err(imp.span, format!("tipo no definido: {}", imp.target)));
                        }
                    }
                };
                if env
                    .trait_impls
                    .borrow()
                    .contains_key(&(trait_id, target_ty))
                {
                    return Err(err(
                        imp.span,
                        format!(
                            "implementación duplicada de trait {trait_name} para {}",
                            env.type_name(target_ty)
                        ),
                    ));
                }
                let tr = &env.traits[trait_id];
                for tm in &tr.methods {
                    let imp_m = imp.methods.iter().find(|m| m.name == tm.name);
                    let Some(m) = imp_m else {
                        if tm.body.is_empty() {
                            return Err(err(
                                imp.span,
                                format!(
                                    "falta el método {} requerido por el trait {trait_name}",
                                    tm.name
                                ),
                            ));
                        }
                        continue;
                    };
                    if m.kind != tm.kind {
                        return Err(err(
                            m.span,
                            format!(
                                "firma incompatible para método {} del trait {trait_name}",
                                m.name
                            ),
                        ));
                    }
                    if m.params.len() != tm.params.len() {
                        return Err(err(
                            m.span,
                            format!(
                                "firma incompatible para método {} del trait {trait_name}",
                                m.name
                            ),
                        ));
                    }
                }
                for m in &imp.methods {
                    let fid = env.sigs.borrow().len();
                    let mut params = Vec::new();
                    let mut param_modes = Vec::new();
                    for (_, t, _) in &m.params {
                        let (ty, mode) = env.resolve_param(t, Some(target_ty), &[])?;
                        params.push(ty);
                        param_modes.push(mode);
                    }
                    let result = match &m.result {
                        Some(t) => Some(env.resolve(t, Some(target_ty), &[])?),
                        None if m.public => Some(Type::Unit),
                        None => None,
                    };
                    let method_name = format!("{}.{}", env.type_name(target_ty), m.name);
                    env.sigs.borrow_mut().push(Sig {
                        is_async: false,
                        async_result: None,
                        name: method_name,
                        kind: m.kind,
                        owner: Some(target_ty),
                        params,
                        param_modes,
                        result,
                        borrow_return: None,
                        view_return: None,
                    });
                    if env
                        .methods
                        .borrow_mut()
                        .insert((target_ty, m.name.clone()), fid)
                        .is_some()
                    {
                        return Err(err(
                            m.span,
                            format!("método duplicado {}.{}", imp.target, m.name),
                        ));
                    }
                    let noalloc = get_noalloc(&m.attributes);
                    env.fn_contracts.borrow_mut().insert(
                        fid,
                        FnContract {
                            name: format!("{}.{}", imp.target, m.name),
                            span: m.span,
                            explicit_effects: m.effects,
                            noalloc,
                        },
                    );
                    env.impl_methods
                        .borrow_mut()
                        .entry((trait_name.clone(), m.name.clone()))
                        .or_default()
                        .push(fid);
                    env.queued_fns.borrow_mut().push(FnToCompile {
                        id: fid,
                        target: FnTarget::Ast(m.clone()),
                    });
                    decls.push((m, Some(target_ty)));
                }
                env.trait_impls
                    .borrow_mut()
                    .insert((trait_id, target_ty), 0);
            }
        } else if let Some(&stid) = env.struct_template_ids.get(&imp.target) {
            for m in &imp.methods {
                env.method_templates.push(MethodTemplate {
                    params: imp.params.clone(),
                    target_template: stid,
                    func: m.clone(),
                    span: m.span,
                });
            }
        } else {
            let owner = if let Some(&sid) = env.struct_ids.get(&imp.target) {
                Type::Struct(sid)
            } else if let Some(&tid) = env.template_ids.get(&imp.target) {
                if !env.templates[tid].params.is_empty() {
                    return Err(err(
                        imp.span,
                        format!(
                            "impl para enum genérico requiere argumentos de tipo: {}",
                            imp.target
                        ),
                    ));
                }
                Type::Enum(env.instantiate(tid, Vec::new(), imp.span)?)
            } else {
                return Err(err(
                    imp.span,
                    format!(
                        "impl requiere un struct o enum declarado en este archivo: {}",
                        imp.target
                    ),
                ));
            };
            for m in &imp.methods {
                if let Some(tid) = env.template_of(owner)
                    && env.variant_index(tid, &m.name).is_some()
                {
                    return Err(err(
                        m.span,
                        format!(
                            "el método {} coincide con una variante de {}",
                            m.name, imp.target
                        ),
                    ));
                }
                let fid = env.sigs.borrow().len();
                let mut params = Vec::new();
                let mut param_modes = Vec::new();
                for (_, t, _) in &m.params {
                    let (ty, mode) = env.resolve_param(t, Some(owner), &[])?;
                    if env.is_view(ty) {
                        return Err(view_escape(m.span));
                    }
                    params.push(ty);
                    param_modes.push(mode);
                }
                let (result, borrow_return, view_return) =
                    env.borrow_result(m, Some(owner), &[], &param_modes)?;
                let method_name = format!("{}.{}", env.type_name(owner), m.name);
                env.sigs.borrow_mut().push(Sig {
                    is_async: false,
                    async_result: None,
                    name: method_name,
                    kind: m.kind,
                    owner: Some(owner),
                    params,
                    param_modes,
                    result,
                    borrow_return,
                    view_return,
                });
                if env
                    .methods
                    .borrow_mut()
                    .insert((owner, m.name.clone()), fid)
                    .is_some()
                {
                    return Err(err(
                        m.span,
                        format!("método duplicado {}.{}", imp.target, m.name),
                    ));
                }
                let noalloc = get_noalloc(&m.attributes);
                env.fn_contracts.borrow_mut().insert(
                    fid,
                    FnContract {
                        name: format!("{}.{}", imp.target, m.name),
                        span: m.span,
                        explicit_effects: m.effects,
                        noalloc,
                    },
                );
                env.queued_fns.borrow_mut().push(FnToCompile {
                    id: fid,
                    target: FnTarget::Ast(m.clone()),
                });
                decls.push((m, Some(owner)));
            }
        }
    }
    Ok((env, decls))
}

fn check_template_signature_type(
    env: &Env,
    t: &TypeExpr,
    params: &[String],
) -> Result<(), Diagnostic> {
    match t {
        TypeExpr::Ref(inner, _, _) => check_template_type(env, inner, params),
        _ => check_template_type(env, t, params),
    }
}

/// Checks that a generic payload type only names known types and parameters.
fn check_template_type(env: &Env, t: &TypeExpr, params: &[String]) -> Result<(), Diagnostic> {
    match t {
        TypeExpr::Prim(_) => Ok(()),
        TypeExpr::Ref(_, _, span) => Err(aggregate_escape(*span)),
        TypeExpr::Array(inner, _, _) | TypeExpr::Slice(inner, _) => {
            check_template_type(env, inner, params)
        }
        TypeExpr::Named(n, args, _) if n == "List" => args
            .iter()
            .try_for_each(|a| check_template_type(env, a, params)),
        TypeExpr::Named(n, _, span) if n == "TaskGroup" => Err(err(
            *span,
            "TaskGroup no se puede almacenar en agregados ni colecciones",
        )
        .classify("L0015", "concurrencia")),
        TypeExpr::Named(n, _, span) if n == "Future" => Err(err(
            *span,
            "Future no se puede almacenar en un agregado ni colecciones",
        )
        .classify("L0015", "concurrencia")),
        TypeExpr::Named(n, args, span) => {
            if params.contains(n) {
                return if args.is_empty() {
                    Ok(())
                } else {
                    Err(err(
                        *span,
                        format!("el parámetro de tipo {n} no admite argumentos"),
                    ))
                };
            }
            if let Some(&tid) = env.template_ids.get(n) {
                if env.templates[tid].params.len() != args.len() {
                    return Err(err(
                        *span,
                        format!(
                            "{n} requiere {} argumento(s) de tipo",
                            env.templates[tid].params.len()
                        ),
                    ));
                }
                return args
                    .iter()
                    .try_for_each(|a| check_template_type(env, a, params));
            }
            if env.struct_ids.contains_key(n) && args.is_empty() {
                return Ok(());
            }
            if let Some(&stid) = env.struct_template_ids.get(n) {
                if env.struct_templates[stid].params.len() != args.len() {
                    return Err(err(
                        *span,
                        format!(
                            "{n} requiere {} argumento(s) de tipo",
                            env.struct_templates[stid].params.len()
                        ),
                    ));
                }
                return args
                    .iter()
                    .try_for_each(|a| check_template_type(env, a, params));
            }
            Err(err(*span, format!("tipo no definido: {n}")))
        }
    }
}

/// Rejects structs/enums that contain themselves by value (infinite size).
fn reject_recursive_types(env: &Env, program: &parser::Program) -> Result<(), Diagnostic> {
    fn children(env: &Env, t: Type) -> Vec<Type> {
        match t {
            Type::Struct(id) => env.structs.borrow()[id]
                .fields
                .iter()
                .map(|(_, t)| *t)
                .collect(),
            Type::Enum(id) => env.enums.borrow()[id]
                .def
                .variants
                .iter()
                .flat_map(|(_, p)| p.clone())
                .collect(),
            _ => Vec::new(),
        }
    }
    fn visit(env: &Env, t: Type, path: &mut Vec<Type>, done: &mut HashSet<Type>) -> Option<Type> {
        if done.contains(&t) {
            return None;
        }
        if path.contains(&t) {
            return Some(t);
        }
        path.push(t);
        for c in children(env, t) {
            if let Some(cycle) = visit(env, c, path, done) {
                return Some(cycle);
            }
        }
        path.pop();
        done.insert(t);
        None
    }
    let roots: Vec<Type> = (0..env.structs.borrow().len()).map(Type::Struct).collect();
    let mut done = HashSet::new();
    for root in roots {
        if let Some(cycle) = visit(env, root, &mut Vec::new(), &mut done) {
            let name = env.type_name(cycle);
            let span = program
                .structs
                .iter()
                .map(|s| (&s.name, s.span))
                .chain(program.enums.iter().map(|e| (&e.name, e.span)))
                .find(|(n, _)| name == **n || name.starts_with(&format!("{n}<")))
                .map(|(_, s)| s)
                .unwrap_or_default();
            return Err(err(
                span,
                format!("{name} se contiene a sí mismo por valor (tamaño infinito)"),
            ));
        }
    }
    Ok(())
}

fn checker<'a>(
    env: &'a Env,
    globals: &'a HashMap<String, Value>,
    owner: Option<Type>,
    result: Option<Type>,
    bindings: Vec<(String, Type)>,
) -> Checker<'a> {
    let root_scope = env.next_scope(0);
    Checker {
        env,
        owner,
        scopes: vec![HashMap::new()],
        scope_stack: vec![root_scope],
        next: 0,
        result,
        loop_depth: 0,
        globals,
        param_bindings: HashSet::new(),
        bindings,
        borrow_allowed: false,
        ref_result_allowed: false,
        storing_value: false,
        view_use: ViewUse::None,
        borrow_return: None,
        view_return: None,
        is_async: false,
        source_file: 0,
    }
}

fn check_defaults(
    env: &mut Env,
    program: &parser::Program,
    globals: &HashMap<String, Value>,
) -> Result<(), Diagnostic> {
    for s in &program.structs {
        let Some(&sid) = env.struct_ids.get(&s.name) else {
            continue;
        };
        let mut defaults = Vec::new();
        for (index, f) in s.fields.iter().enumerate() {
            let Some(expr) = &f.default else {
                defaults.push(None);
                continue;
            };
            let field_ty = env.structs.borrow()[sid].fields[index].1;
            let value = checker(env, globals, Some(Type::Struct(sid)), None, Vec::new()).expr(
                expr,
                0,
                Some(field_ty),
            )?;
            env.same(field_ty, value.ty, value.span)?;
            let value = crate::consteval::evaluate(&value).map_err(|mut e| {
                e.message = format!(
                    "valor predeterminado de {}.{} debe ser constante: {}",
                    s.name, f.name, e.message
                );
                e
            })?;
            defaults.push(Some(value));
        }
        env.structs.borrow_mut()[sid].defaults = defaults;
    }
    Ok(())
}

fn lower(
    env: &Env,
    globals: &HashMap<String, Value>,
    f: &parser::Function,
    id: usize,
    bindings: &[(String, Type)],
) -> Result<Function, Diagnostic> {
    let (sig_name, sig_kind, sig_owner, sig_result, sig_params, sig_param_modes, is_async) = {
        let sigs = env.sigs.borrow();
        let sig = &sigs[id];
        (
            sig.name.clone(),
            sig.kind,
            sig.owner,
            if sig.is_async {
                sig.async_result
            } else {
                sig.result
            },
            sig.params.clone(),
            sig.param_modes.clone(),
            sig.is_async,
        )
    };
    let body_stmts = if is_async {
        crate::async_desugar::desugar_async_stmts(&f.body)?
    } else {
        f.body.clone()
    };
    check_await_positions(&body_stmts, is_async)?;
    if is_async && !f.type_params.is_empty() {
        return Err(async_error(
            f.span,
            "feature not implemented: funciones async genéricas",
        ));
    }
    let mut c = checker(env, globals, sig_owner, sig_result, bindings.to_vec());
    c.is_async = is_async;
    c.source_file = f.span.file;
    c.borrow_return = env.sigs.borrow()[id].borrow_return.clone();
    c.view_return = env.sigs.borrow()[id].view_return.clone();
    let receiver = match (sig_kind, sig_owner) {
        (FnKind::Method, Some(owner)) => {
            let id = c.bind_ref("self", owner, false, Some(Receiver::Shared), f.span)?;
            c.param_bindings.insert(id);
            Some((id, owner, Receiver::Shared))
        }
        (FnKind::MutMethod, Some(owner)) => {
            let id = c.bind_ref("self", owner, true, Some(Receiver::Exclusive), f.span)?;
            c.param_bindings.insert(id);
            Some((id, owner, Receiver::Exclusive))
        }
        _ => None,
    };
    let mut params = Vec::new();
    for (((n, _, sp), t), mode) in f.params.iter().zip(&sig_params).zip(&sig_param_modes) {
        let is_mut = *mode == Some(Receiver::Exclusive);
        let id = c.bind_ref(n, *t, is_mut, *mode, *sp)?;
        c.param_bindings.insert(id);
        params.push((id, *t));
    }
    let (body, returns) = c.block(&body_stmts, false, true)?;
    let result = c.result.unwrap_or(Type::Unit);
    if f.result.is_none() && matches!(result, Type::Future(_) | Type::Task(_)) {
        return Err(async_error(
            f.span,
            "un future o un TaskHandle solo se puede consumir con await dentro de la función async que lo creó: no se puede devolver ni almacenar sin anotación explícita",
        ));
    }
    if matches!(result, Type::Task(_)) {
        return Err(async_error(
            f.span,
            "un TaskHandle solo se puede consumir con await dentro de la función async que lo creó: no se puede devolver ni almacenar",
        ));
    }
    check_handle_positions(env, &body)?;
    if is_async {
        check_async_state(env, &body)?;
    }
    if (result != Type::Unit || c.borrow_return.is_some() || c.view_return.is_some()) && !returns {
        return Err(err(f.span, "falta retorno en alguna ruta de la función"));
    }
    Ok(Function {
        name: sig_name,
        is_async,
        receiver,
        params,
        param_modes: sig_param_modes,
        result,
        borrow_return: c.borrow_return,
        view_return: c.view_return,
        body,
        by_value_bindings: HashSet::new(),
        effects: EffectSet::EMPTY,
    })
}

fn lower_target(
    env: &Env,
    globals: &HashMap<String, Value>,
    item: &FnToCompile,
) -> Result<Function, Diagnostic> {
    match &item.target {
        FnTarget::YieldNow => Ok(Function {
            name: YIELD_NOW.into(),
            is_async: true,
            receiver: None,
            params: Vec::new(),
            param_modes: Vec::new(),
            result: Type::Unit,
            borrow_return: None,
            view_return: None,
            body: vec![Instruction::Yield],
            by_value_bindings: HashSet::new(),
            effects: EffectSet::EMPTY,
        }),
        FnTarget::Sleep => Ok(Function {
            name: SLEEP_MS.into(),
            is_async: true,
            receiver: None,
            params: vec![(0, Type::Int)],
            param_modes: vec![None],
            result: Type::Unit,
            borrow_return: None,
            view_return: None,
            body: vec![Instruction::Sleep(Value {
                kind: ValueKind::Local(0),
                ty: Type::Int,
                span: Span::at(1, 1),
            })],
            by_value_bindings: HashSet::new(),
            effects: EffectSet::EMPTY,
        }),
        FnTarget::Ast(f) => lower(env, globals, f, item.id, &[]),
        FnTarget::Specialized {
            template_id,
            bindings,
        } => {
            let f = env.fn_templates[*template_id].func.clone();
            lower(env, globals, &f, item.id, bindings)
        }
        FnTarget::SpecializedMethod { bindings, func } => {
            lower(env, globals, func, item.id, bindings)
        }
    }
}

pub fn check(program: parser::Program) -> Result<Program, Diagnostic> {
    let prelude = prelude();
    let (mut env, decls) = declare(&program, &prelude)?;
    let globals = global_constants(&program.constants, &env)?;
    check_defaults(&mut env, &program, &globals)?;
    // The loader assigns file 1 to the entry source, even though imported
    // declarations are merged first. A dependency's public or private main
    // must never become the program's entry point through the global table.
    // Standalone (non-modular) parsing uses file 0.
    let entry_file = if program.functions.iter().any(|f| f.span.file != 0) {
        1
    } else {
        0
    };
    let main = *env
        .module_functions
        .borrow()
        .get(&(entry_file, "main".to_owned()))
        .ok_or_else(|| err(Span::at(1, 1), "falta fn main()"))?;

    let mut lowered: Vec<Option<Function>> = Vec::new();
    loop {
        let mut progress = false;
        let mut pending = None;
        let count = env.queued_fns.borrow().len();
        while lowered.len() < count {
            lowered.push(None);
        }
        for i in 0..count {
            if lowered[i].is_some() {
                continue;
            }
            let item = env.queued_fns.borrow()[i].clone();
            match lower_target(&env, &globals, &item) {
                Ok(function) => {
                    // An async signature already holds its future type.
                    if !env.sigs.borrow()[item.id].is_async {
                        env.sigs.borrow_mut()[item.id].result = Some(function.result);
                    }
                    lowered[item.id] = Some(function);
                    progress = true;
                }
                Err(e) if e.code == INFER_CODE => {
                    pending.get_or_insert(e);
                }
                Err(e) => return Err(e),
            }
        }
        if env.queued_fns.borrow().len() > count {
            continue;
        }
        match pending {
            None => break,
            Some(e) if !progress => return Err(e),
            Some(_) => {}
        }
    }
    let functions: Vec<Function> = lowered.into_iter().flatten().collect();
    let entry = &functions[main];
    let main_decl = decls
        .iter()
        .find(|d| d.0.name == "main" && d.0.span.file == entry_file)
        .map(|d| d.0);
    let has_exit_code = entry.result == Type::Int
        && !entry.is_async
        && entry.borrow_return.is_none()
        && main_decl.is_some_and(|decl| decl.result.is_some());
    if !(entry.params.is_empty()
        && (entry.result == Type::Unit || has_exit_code)
        && env.sigs.borrow()[main].kind == FnKind::Free)
    {
        let main_span = main_decl.map(|d| d.span).unwrap_or_default();
        return Err(err(
            main_span,
            format!(
                "main debe tener firma fn main() -> () o fn main() -> Int explícita y síncrona (resultado: {}; use ';' para descartar el valor final)",
                env.type_name(entry.result)
            ),
        ));
    }
    let mut program = Program {
        structs: env
            .structs
            .into_inner()
            .iter()
            .map(|s| StructDef {
                name: s.name.clone(),
                fields: s.fields.clone(),
            })
            .collect(),
        enums: env.enums.into_inner().into_iter().map(|e| e.def).collect(),
        arrays: env.arrays.into_inner(),
        slices: env.slices.into_inner(),
        lists: env.lists.into_inner(),
        task_groups: env.task_groups.into_inner(),
        futures: env.futures.into_inner(),
        functions,
        main,
    };
    crate::ownership::check(&mut program)?;
    let contracts = env.fn_contracts.into_inner();
    let impl_methods = env.impl_methods.into_inner();
    crate::effects::check_effects(
        &mut program,
        &contracts,
        &env.trait_contracts,
        &impl_methods,
    )?;
    Ok(program)
}

fn global_constants(
    decls: &[parser::Constant],
    env: &Env,
) -> Result<HashMap<String, Value>, Diagnostic> {
    for c in decls {
        if crate::async_desugar::has_await(&c.value) {
            return Err(async_error(
                c.value.span,
                "await solo se puede usar dentro de una función async",
            ));
        }
    }
    let mut names = HashSet::new();
    for c in decls {
        if c.name == "print"
            || env.functions.borrow().contains_key(&c.name)
            || env
                .module_functions
                .borrow()
                .keys()
                .any(|(_, name)| name == &c.name)
            || env.struct_ids.contains_key(&c.name)
            || env.struct_template_ids.contains_key(&c.name)
            || env.template_ids.contains_key(&c.name)
            || env.unqualified.contains_key(&c.name)
            || !names.insert(c.name.clone())
        {
            return Err(err(
                c.span,
                format!("nombre duplicado o reservado: {}", c.name),
            ));
        }
    }
    let mut values = HashMap::new();
    // Topological resolution without recursive evaluation across declarations.
    while values.len() < decls.len() {
        let before = values.len();
        for c in decls {
            if values.contains_key(&c.name) || !ready(&c.value, &names, &values, 0)? {
                continue;
            }
            let annotation = match &c.annotation {
                Some(t) => Some(env.resolve(t, None, &[])?),
                None => None,
            };
            let value =
                checker(env, &values, None, None, Vec::new()).expr(&c.value, 0, annotation)?;
            if let Some(ty) = annotation {
                env.same(ty, value.ty, c.span)?;
            }
            let value = crate::consteval::evaluate(&value)?;
            values.insert(c.name.clone(), value);
        }
        if before == values.len() {
            let c = decls.iter().find(|c| !values.contains_key(&c.name));
            return Err(err(
                c.map(|c| c.span).unwrap_or_default(),
                "dependencia circular entre constantes",
            ));
        }
    }
    Ok(values)
}
fn ready(
    e: &parser::Expr,
    names: &HashSet<String>,
    values: &HashMap<String, Value>,
    depth: usize,
) -> Result<bool, Diagnostic> {
    if depth > 128 {
        return Err(err(e.span, "expresión constante demasiado profunda"));
    }
    Ok(match &e.kind {
        ExprKind::Name(n) => !names.contains(n) || values.contains_key(n),
        ExprKind::Unary(_, a) => ready(a, names, values, depth + 1)?,
        ExprKind::Binary(_, a, b) => {
            ready(a, names, values, depth + 1)? && ready(b, names, values, depth + 1)?
        }
        ExprKind::Interpolate(parts)
        | ExprKind::Call(_, parts)
        | ExprKind::GenericCall(_, _, parts) => {
            let mut result = true;
            for part in parts {
                result &= ready(part, names, values, depth + 1)?;
            }
            result
        }
        ExprKind::MethodCall(base, _, parts) | ExprKind::GenericMethodCall(base, _, _, parts) => {
            let mut result = ready(base, names, values, depth + 1)?;
            for part in parts {
                result &= ready(part, names, values, depth + 1)?;
            }
            result
        }
        // Other forms are rejected by consteval, regardless of their operands.
        _ => true,
    })
}

// --------------------------------------------------------------- async -----

/// Name of the built-in suspension primitive.
const YIELD_NOW: &str = "yieldNow";
const JOIN: &str = "join";
const JOIN_ALL: &str = "joinAll";
const TASK_GROUP: &str = "taskGroup";

fn async_error(span: Span, message: impl Into<String>) -> Diagnostic {
    err(span, message).classify("L0015", "async")
}

/// Rejects `await` outside an async function, and in constant declarations.
fn check_await_positions(body: &[parser::Stmt], is_async: bool) -> Result<(), Diagnostic> {
    if !is_async {
        let mut found = None;
        walk_stmts(body, &mut |x| {
            if found.is_none() && matches!(x.kind, ExprKind::Await(_)) {
                found = Some(x.span);
            }
        });
        if let Some(span) = found {
            return Err(async_error(
                span,
                "await solo se puede usar dentro de una función async",
            ));
        }
    } else {
        for stmt in body {
            if let parser::Stmt::Const(c) = stmt
                && crate::async_desugar::has_await(&c.value)
            {
                return Err(async_error(
                    c.value.span,
                    "await solo se puede usar dentro de una función async",
                ));
            }
        }
    }
    Ok(())
}

/// Visits every expression of `body`, including nested statements.
fn walk_stmts(body: &[parser::Stmt], f: &mut impl FnMut(&parser::Expr)) {
    use parser::Stmt;
    for stmt in body {
        match stmt {
            Stmt::Let(_, _, _, e) | Stmt::Return(e) | Stmt::Expr(e, _) => walk_expr(e, f),
            Stmt::Assign(target, _, e, _) => {
                walk_expr(target, f);
                walk_expr(e, f);
            }
            Stmt::Const(c) => walk_expr(&c.value, f),
            Stmt::If(c, yes, no, _) => {
                walk_expr(c, f);
                walk_stmts(yes, f);
                walk_stmts(no, f);
            }
            Stmt::While(c, b) => {
                walk_expr(c, f);
                walk_stmts(b, f);
            }
            Stmt::For(_, _, from, to, _, b) => {
                walk_expr(from, f);
                walk_expr(to, f);
                walk_stmts(b, f);
            }
            Stmt::ForEach(_, _, coll, b) => {
                walk_expr(coll, f);
                walk_stmts(b, f);
            }
            Stmt::Loop(b) | Stmt::Block(b, _) | Stmt::Region(_, _, b) => walk_stmts(b, f),
            Stmt::Break(_) | Stmt::Continue(_) => {}
        }
    }
}

/// Visits every sub-expression of `e`, including match arms and interpolation.
fn walk_expr(e: &parser::Expr, f: &mut impl FnMut(&parser::Expr)) {
    f(e);
    match &e.kind {
        ExprKind::Interpolate(parts) | ExprKind::ArrayLit(parts) | ExprKind::ListLit(parts) => {
            for p in parts {
                walk_expr(p, f);
            }
        }
        ExprKind::Call(_, args) | ExprKind::GenericCall(_, _, args) => {
            for a in args {
                walk_expr(a, f);
            }
        }
        ExprKind::MethodCall(base, _, args) | ExprKind::GenericMethodCall(base, _, _, args) => {
            walk_expr(base, f);
            for a in args {
                walk_expr(a, f);
            }
        }
        ExprKind::Named(_, inner)
        | ExprKind::Field(inner, _)
        | ExprKind::Try(inner)
        | ExprKind::Await(inner)
        | ExprKind::Spawn(inner)
        | ExprKind::Unary(_, inner) => walk_expr(inner, f),
        ExprKind::Index(a, b) | ExprKind::Binary(_, a, b) => {
            walk_expr(a, f);
            walk_expr(b, f);
        }
        ExprKind::Match(scrutinee, arms) => {
            walk_expr(scrutinee, f);
            for arm in arms {
                walk_stmts(&arm.body, f);
            }
        }
        ExprKind::Int(_)
        | ExprKind::Float(_)
        | ExprKind::Bool(_)
        | ExprKind::Unit
        | ExprKind::Text(_)
        | ExprKind::Name(_) => {}
    }
}

/// Rejects reads of locals that live only in the current poll frame after it
/// may have ended, including references to otherwise persistent values.
fn check_async_state(env: &Env, body: &[Instruction]) -> Result<(), Diagnostic> {
    #[derive(Clone)]
    struct Scan<'a> {
        env: &'a Env,
        /// Locals that own resources and are initialized at this point.
        owning: HashMap<usize, (Type, Span)>,
        /// Owning locals whose value does not survive the latest suspension.
        risky: HashMap<usize, (Type, Span)>,
        references: HashSet<usize>,
    }
    impl Scan<'_> {
        fn suspend(&mut self, span: Span) -> Result<(), Diagnostic> {
            // A region lives in the frame of the poll call, which ends at the
            // suspension: its storage would be released under the task's feet.
            if let Some((ty, _)) = self.owning.values().find(|(ty, _)| ty.is_region_bound()) {
                return Err(async_error(
                    span,
                    format!(
                        "no se puede suspender mientras una región está abierta: {} y sus reservas se liberarían al suspender",
                        self.env.type_name(*ty)
                    ),
                ));
            }
            for (id, info) in &self.owning {
                self.risky.insert(*id, *info);
            }
            Ok(())
        }
        fn define(&mut self, id: usize, ty: Type, span: Span) {
            self.risky.remove(&id);
            // Persistent owners live in the future, not in the poll frame.
            if (ty.is_move()
                && !matches!(ty, Type::Task(_) | Type::TaskGroup(_))
                && self.env.group_task(ty).is_none()
                && !self.env.async_owned(ty))
                || matches!(ty, Type::SharedField(_) | Type::MutField(_))
            {
                self.owning.insert(id, (ty, span));
            }
        }
        fn value(&mut self, v: &Value) -> Result<(), Diagnostic> {
            let mut result = Ok(());
            let mut suspends = false;
            visit_values(v, &mut |x| {
                if result.is_err() {
                    return;
                }
                let root = match &x.kind {
                    ValueKind::Local(id) => Some(*id),
                    ValueKind::Borrow(p, _)
                    | ValueKind::MethodCall(_, p, _, _)
                    | ValueKind::RegionBytes(p, _)
                    | ValueKind::RegionList(p)
                    | ValueKind::BytesLen(p)
                    | ValueKind::BytesGet(p, _)
                    | ValueKind::BytesSet(p, _, _) => Some(p.root),
                    _ => None,
                };
                if let Some(id) = root
                    && let Some((ty, _)) = self.risky.get(&id)
                {
                    let message = if self.references.contains(&id) {
                        "el préstamo no sobrevive a una suspensión: créelo después del await".into()
                    } else {
                        format!(
                            "el valor de tipo {} no sobrevive a una suspensión: se libera antes de suspender y no puede usarse después del await",
                            self.env.type_name(*ty)
                        )
                    };
                    result = Err(async_error(x.span, message));
                }
                if let ValueKind::Match(_, arms) = &x.kind {
                    for arm in arms {
                        result = self.clone().block(&arm.body);
                        if result.is_err() {
                            break;
                        }
                    }
                }
                if matches!(
                    x.kind,
                    ValueKind::Await(_) | ValueKind::Join(_) | ValueKind::JoinAll(_)
                ) {
                    suspends = true;
                }
            });
            result?;
            let mut consumed = Vec::new();
            visit_values(v, &mut |x| {
                if let ValueKind::Await(future) = &x.kind
                    && let ValueKind::Local(id) = future.kind
                {
                    consumed.push(id);
                }
            });
            for id in consumed {
                self.owning.remove(&id);
                self.risky.remove(&id);
            }
            if suspends {
                self.suspend(v.span)?;
            }
            Ok(())
        }
        fn block(&mut self, body: &[Instruction]) -> Result<(), Diagnostic> {
            for i in body {
                match i {
                    Instruction::Yield => self.suspend(Span::at(1, 1))?,
                    Instruction::Sleep(v) => {
                        self.value(v)?;
                        self.suspend(v.span)?;
                    }
                    Instruction::Bind(id, _, v) => {
                        self.value(v)?;
                        self.define(*id, v.ty, v.span);
                    }
                    Instruction::BindRef(id, _, ty, v) => {
                        self.value(v)?;
                        self.risky.remove(id);
                        self.owning.insert(*id, (*ty, v.span));
                        self.references.insert(*id);
                    }
                    Instruction::Store(place, v) => {
                        self.value(v)?;
                        if place.fields.is_empty() && !self.references.contains(&place.root) {
                            // A plain assignment revives the local.
                            self.risky.remove(&place.root);
                        } else if let Some((ty, _)) = self.risky.get(&place.root) {
                            let message = if self.references.contains(&place.root) {
                                "el préstamo no sobrevive a una suspensión: no puede escribir a través de él después del await".into()
                            } else {
                                format!(
                                    "el valor de tipo {} no sobrevive a una suspensión: no se puede escribir en ese lugar tras el await",
                                    self.env.type_name(*ty)
                                )
                            };
                            return Err(async_error(v.span, message));
                        }
                    }
                    Instruction::Eval(v)
                    | Instruction::Return(v)
                    | Instruction::ReturnRef(_, v) => self.value(v)?,
                    Instruction::StoreElem(a, b) => {
                        self.value(b)?;
                        self.value(a)?;
                    }
                    Instruction::If(c, yes, no) => {
                        self.value(c)?;
                        let before = self.risky.clone();
                        self.block(yes)?;
                        let after_yes = std::mem::replace(&mut self.risky, before);
                        self.block(no)?;
                        self.risky.extend(after_yes);
                    }
                    // A collection being iterated is borrowed for the whole
                    // loop, and the borrow cannot survive a suspension.
                    Instruction::ForEach(_, _, c, b) if suspends(b) => {
                        return Err(async_error(
                            c.span,
                            "no se puede suspender dentro de un for sobre una colección: el préstamo del recorrido no sobrevive a la suspensión; recorra índices con while",
                        ));
                    }
                    Instruction::While(c, b) | Instruction::ForEach(_, _, c, b) => {
                        // Re-evaluating the condition is also part of the
                        // back-edge of a while loop that can suspend.
                        if suspends(b) {
                            self.suspend(c.span)?;
                        }
                        self.value(c)?;
                        self.block(b)?;
                    }
                    Instruction::ForRange(id, from, to, _, b) => {
                        self.value(from)?;
                        self.value(to)?;
                        self.define(*id, Type::Int, from.span);
                        if suspends(b) {
                            self.suspend(from.span)?;
                        }
                        self.block(b)?;
                    }
                    Instruction::Loop(b) | Instruction::Block(b) => {
                        if matches!(i, Instruction::Loop(_)) && suspends(b) {
                            self.suspend(Span::at(1, 1))?;
                        }
                        self.block(b)?;
                    }
                    Instruction::Break | Instruction::Continue => {}
                }
            }
            Ok(())
        }
    }
    let mut scan = Scan {
        env,
        owning: HashMap::new(),
        risky: HashMap::new(),
        references: HashSet::new(),
    };
    scan.block(body)
}

/// Rejects a future or a task handle anywhere other than the places where the
/// language allows one: the value of a binding or of an assignment, a statement
/// of its own, and the operand of `await` or of `spawn`. They are opaque
/// handles with no type syntax, so they must not end up inside an aggregate, in
/// an argument, in an interpolation or in any other composite value, where
/// nothing would keep them tied to the async scope that owns them.
fn check_handle_positions(env: &Env, body: &[Instruction]) -> Result<(), Diagnostic> {
    fn opaque(t: Type) -> bool {
        matches!(t, Type::Task(_))
    }
    fn value(env: &Env, v: &Value, allowed: bool) -> Result<(), Diagnostic> {
        let is_grp = env.group_task(v.ty).is_some() || matches!(v.ty, Type::TaskGroup(_));
        if is_grp && (!allowed || !matches!(v.kind, ValueKind::Local(_) | ValueKind::ListLit(_))) {
            return Err(async_error(
                v.span,
                "el grupo de tareas solo puede moverse entre locales del mismo ámbito async: no se puede almacenar en un agregado, prestar, indexar ni devolver",
            ));
        }
        if !allowed && opaque(v.ty) {
            return Err(async_error(
                v.span,
                format!(
                    "{} solo se puede guardar en una variable local y consumirse con await en la misma función async: no se puede almacenar en un agregado, pasar como argumento ni usar en una expresión compuesta",
                    env.type_name(v.ty)
                ),
            ));
        }
        match &v.kind {
            // The operand of `await`/`spawn` is exactly where a handle belongs.
            ValueKind::Await(inner) | ValueKind::Spawn(inner) => value(env, inner, true),
            ValueKind::JoinAll(group) => value(env, group, true),
            ValueKind::ListLit(items)
                if env.group_task(v.ty).is_some() || matches!(v.ty, Type::TaskGroup(_)) =>
            {
                for item in items {
                    value(env, item, true)?;
                }
                Ok(())
            }
            ValueKind::ListPush(group, item)
                if env.group_task(group.ty).is_some() || matches!(group.ty, Type::TaskGroup(_)) =>
            {
                value(env, group, true)?;
                value(env, item, true)
            }
            ValueKind::ListReserve(group, n)
                if env.group_task(group.ty).is_some() || matches!(group.ty, Type::TaskGroup(_)) =>
            {
                value(env, group, true)?;
                value(env, n, false)
            }
            ValueKind::Length(group) | ValueKind::Capacity(group)
                if env.group_task(group.ty).is_some() || matches!(group.ty, Type::TaskGroup(_)) =>
            {
                value(env, group, true)
            }
            ValueKind::Join(handles) => {
                for handle in handles.iter() {
                    value(env, handle, true)?;
                }
                Ok(())
            }
            ValueKind::Match(_, arms) => {
                for arm in arms {
                    block(env, &arm.body)?;
                }
                for x in children(v) {
                    value(env, x, false)?;
                }
                Ok(())
            }
            _ => {
                for x in children(v) {
                    value(env, x, false)?;
                }
                Ok(())
            }
        }
    }
    /// Direct sub-values of `v`, one level down. `value` recurses, so the rule
    /// of each node is decided by its own position, not by its ancestors'.
    fn children(v: &Value) -> Vec<&Value> {
        let mut out: Vec<&Value> = Vec::new();
        match &v.kind {
            ValueKind::Interpolate(vs)
            | ValueKind::ArrayLit(vs)
            | ValueKind::ListLit(vs)
            | ValueKind::Call(_, vs)
            | ValueKind::Variant(_, _, vs)
            | ValueKind::MethodCall(_, _, _, vs) => out.extend(vs),
            ValueKind::TempMethodCall(_, base, vs) => {
                out.push(base);
                out.extend(vs);
            }
            ValueKind::Join(handles) => out.extend(handles.iter()),
            ValueKind::Construct(_, fields) => out.extend(fields.iter().map(|(_, x)| x)),
            ValueKind::Field(b, _)
            | ValueKind::SharedField(b, _)
            | ValueKind::StoredBorrow(b)
            | ValueKind::Print(b)
            | ValueKind::Unary(_, b)
            | ValueKind::Convert(b, _)
            | ValueKind::Length(b)
            | ValueKind::Capacity(b)
            | ValueKind::Await(b)
            | ValueKind::JoinAll(b)
            | ValueKind::Spawn(b)
            | ValueKind::ListPop(b, ..)
            | ValueKind::RegionBytes(_, b)
            | ValueKind::BytesGet(_, b) => out.push(b),
            ValueKind::Platform(_, args) => out.extend(args),
            ValueKind::Binary(_, a, b)
            | ValueKind::Index(a, b)
            | ValueKind::TextByte(a, b)
            | ValueKind::ListPush(a, b)
            | ValueKind::ListReserve(a, b)
            | ValueKind::BytesSet(_, a, b) => {
                out.push(a);
                out.push(b);
            }
            ValueKind::Match(scrutinee, arms) => {
                out.push(scrutinee);
                out.extend(arms.iter().filter_map(|a| a.value.as_ref()));
            }
            ValueKind::Int(_)
            | ValueKind::Float(_)
            | ValueKind::Bool(_)
            | ValueKind::Text(_)
            | ValueKind::Unit
            | ValueKind::Local(_)
            | ValueKind::Borrow(..)
            | ValueKind::RegionNew
            | ValueKind::RegionList(_)
            | ValueKind::BytesLen(_) => {}
        }
        out
    }
    fn block(env: &Env, body: &[Instruction]) -> Result<(), Diagnostic> {
        for i in body {
            match i {
                // A handle may be the whole value of a binding, of an
                // assignment to a local, or of a statement on its own.
                Instruction::Bind(_, _, v) | Instruction::Eval(v) => value(env, v, true)?,
                Instruction::Store(place, v) => value(env, v, place.fields.is_empty())?,
                Instruction::BindRef(_, _, _, v)
                | Instruction::Return(v)
                | Instruction::ReturnRef(_, v) => value(env, v, false)?,
                Instruction::StoreElem(a, b) => {
                    value(env, a, false)?;
                    value(env, b, false)?;
                }
                Instruction::If(c, yes, no) => {
                    value(env, c, false)?;
                    block(env, yes)?;
                    block(env, no)?;
                }
                Instruction::While(c, b) | Instruction::ForEach(_, _, c, b) => {
                    value(env, c, false)?;
                    block(env, b)?;
                }
                Instruction::ForRange(_, from, to, _, b) => {
                    value(env, from, false)?;
                    value(env, to, false)?;
                    block(env, b)?;
                }
                Instruction::Loop(b) | Instruction::Block(b) => block(env, b)?,
                Instruction::Sleep(v) => value(env, v, false)?,
                Instruction::Yield | Instruction::Break | Instruction::Continue => {}
            }
        }
        Ok(())
    }
    block(env, body)
}

/// Whether `body` contains a suspension point (`await` or `yield`).
fn suspends(body: &[Instruction]) -> bool {
    body.iter().any(|i| match i {
        Instruction::Yield | Instruction::Sleep(_) => true,
        Instruction::Bind(_, _, v)
        | Instruction::BindRef(_, _, _, v)
        | Instruction::Store(_, v)
        | Instruction::Eval(v)
        | Instruction::Return(v)
        | Instruction::ReturnRef(_, v) => value_suspends(v),
        Instruction::StoreElem(a, b) => value_suspends(a) || value_suspends(b),
        Instruction::If(c, yes, no) => value_suspends(c) || suspends(yes) || suspends(no),
        Instruction::While(c, b) | Instruction::ForEach(_, _, c, b) => {
            value_suspends(c) || suspends(b)
        }
        Instruction::ForRange(_, a, b, _, body) => {
            value_suspends(a) || value_suspends(b) || suspends(body)
        }
        Instruction::Loop(b) | Instruction::Block(b) => suspends(b),
        Instruction::Break | Instruction::Continue => false,
    })
}

fn value_suspends(v: &Value) -> bool {
    let mut found = false;
    visit_values(v, &mut |x| {
        if matches!(
            x.kind,
            ValueKind::Await(_) | ValueKind::Join(_) | ValueKind::JoinAll(_)
        ) {
            found = true;
        }
    });
    found
}

/// Visits `v` and every value nested in it (including match arm bodies).
pub(crate) fn visit_values(v: &Value, f: &mut impl FnMut(&Value)) {
    f(v);
    let mut each = |x: &Value| visit_values(x, f);
    match &v.kind {
        ValueKind::Interpolate(vs) | ValueKind::ArrayLit(vs) | ValueKind::ListLit(vs) => {
            vs.iter().for_each(each)
        }
        ValueKind::Call(_, vs) | ValueKind::Variant(_, _, vs) => vs.iter().for_each(each),
        ValueKind::Join(handles) => handles.iter().for_each(each),
        ValueKind::MethodCall(_, _, _, vs) => vs.iter().for_each(each),
        ValueKind::TempMethodCall(_, base, vs) => {
            each(base);
            vs.iter().for_each(each);
        }
        ValueKind::Construct(_, fields) => fields.iter().for_each(|(_, x)| each(x)),
        ValueKind::Platform(_, args) => args.iter().for_each(each),
        ValueKind::Field(b, _)
        | ValueKind::SharedField(b, _)
        | ValueKind::StoredBorrow(b)
        | ValueKind::Print(b)
        | ValueKind::Unary(_, b)
        | ValueKind::Convert(b, _)
        | ValueKind::Length(b)
        | ValueKind::Capacity(b)
        | ValueKind::Await(b)
        | ValueKind::JoinAll(b)
        | ValueKind::Spawn(b) => each(b),
        ValueKind::Binary(_, a, b)
        | ValueKind::Index(a, b)
        | ValueKind::TextByte(a, b)
        | ValueKind::ListPush(a, b)
        | ValueKind::ListReserve(a, b) => {
            each(a);
            each(b);
        }
        ValueKind::ListPop(b, ..) => each(b),
        ValueKind::RegionBytes(_, b) | ValueKind::BytesGet(_, b) => each(b),
        ValueKind::BytesSet(_, a, b) => {
            each(a);
            each(b);
        }
        ValueKind::Match(scrutinee, arms) => {
            each(scrutinee);
            for arm in arms {
                if let Some(value) = &arm.value {
                    each(value);
                }
            }
        }
        ValueKind::Int(_)
        | ValueKind::Float(_)
        | ValueKind::Bool(_)
        | ValueKind::Text(_)
        | ValueKind::Unit
        | ValueKind::Local(_)
        | ValueKind::Borrow(..)
        | ValueKind::RegionNew
        | ValueKind::RegionList(_)
        | ValueKind::BytesLen(_) => {}
    }
}
