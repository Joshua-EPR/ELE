//! Native backend through Rust source. Only accepts resolved, typed LIR.
//! Provisional: see docs/BACKEND.md. Nothing here depends on parser or sema.
use crate::lir::{
    Arm, Instruction, Pattern, Place, PlatformOp, Program, Receiver, Type, Value, ValueKind,
};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, HashMap, HashSet};

/// Per-function emission context. `refs` are locals that are shared borrows
/// (the implicit `self` and borrowing pattern bindings), emitted as `(*vN)`.
struct Emitter<'a> {
    program: &'a Program,
    refs: RefCell<HashSet<usize>>,
    by_value: &'a HashSet<usize>,
    /// Counter for pattern temporaries used by guards.
    temps: Cell<usize>,
    local_types: RefCell<HashMap<usize, Type>>,
}

type ProgramTables = (
    Vec<crate::lir::ArrayDef>,
    Vec<Type>,
    Vec<Type>,
    Vec<crate::lir::TaskGroupDef>,
    Vec<crate::lir::FutureDef>,
);

thread_local! {
    /// Collection type tables of the program being emitted (arrays, slices, lists, task groups, futures).
    static TABLES: RefCell<ProgramTables> =
        const { RefCell::new((Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new())) };
    static LIFETIMES: RefCell<(BTreeSet<usize>, BTreeSet<usize>)> =
        const { RefCell::new((BTreeSet::new(), BTreeSet::new())) };
}

fn borrow_prefix(mode: Receiver, named: bool) -> &'static str {
    match (mode, named) {
        (Receiver::Shared, false) => "&",
        (Receiver::Exclusive, false) => "&mut ",
        (Receiver::Shared, true) => "&'l ",
        (Receiver::Exclusive, true) => "&'l mut ",
    }
}

fn ty(t: Type) -> String {
    match t {
        Type::Array(a) => {
            let def = TABLES.with(|t| t.borrow().0[a]);
            format!("[{}; {}]", ty(def.elem), def.len)
        }
        Type::Slice(s) => format!("[{}]", ty(TABLES.with(|t| t.borrow().1[s]))),
        Type::RegionList(l, _) => {
            format!("LRegionList<'_, {}>", ty(TABLES.with(|t| t.borrow().2[l])))
        }
        Type::List(l) => format!("Vec<{}>", ty(TABLES.with(|t| t.borrow().2[l]))),
        Type::TaskGroup(g) => {
            let elem = TABLES.with(|t| t.borrow().3[g].elem);
            format!("Vec<LTask<{}>>", ty(elem))
        }
        Type::Task(t) => {
            let elem = TABLES.with(|tbl| tbl.borrow().4[t].result);
            format!("LTask<{}>", ty(elem))
        }
        Type::Int => "i64".into(),
        Type::Float => "f64".into(),
        Type::F32 => "f32".into(),
        Type::Bool => "bool".into(),
        Type::Text => "LText".into(),
        Type::Unit => "()".into(),
        Type::SharedField(target) => format!("&'l {}", ty(target.referent())),
        Type::MutField(target) => format!("&'l mut {}", ty(target.referent())),
        Type::Struct(id) => {
            if LIFETIMES.with(|l| l.borrow().0.contains(&id)) {
                format!("S{id}<'l>")
            } else {
                format!("S{id}")
            }
        }
        Type::Enum(id) => {
            if LIFETIMES.with(|l| l.borrow().1.contains(&id)) {
                format!("E{id}<'l>")
            } else {
                format!("E{id}")
            }
        }
        Type::Future(f) => {
            let elem = TABLES.with(|tbl| tbl.borrow().4[f].result);
            format!("LFuture<{}>", ty(elem))
        }
        Type::Region(_) => "LRegion".into(),
        Type::Bytes(_) => "LBytes".into(),
    }
}

/// Whether a value denotes a place (a local, a field or an element of one).
fn is_place(v: &Value) -> bool {
    match &v.kind {
        ValueKind::Local(_) => true,
        ValueKind::Field(b, _) | ValueKind::SharedField(b, _) | ValueKind::Index(b, _) => {
            is_place(b)
        }
        _ => false,
    }
}

impl Emitter<'_> {
    /// Read-only place expression for `v` (a place or an element of one).
    fn read_place(&self, v: &Value) -> String {
        match &v.kind {
            ValueKind::Local(id) => {
                if matches!(v.ty, Type::SharedField(_) | Type::MutField(_)) {
                    format!("v{id}")
                } else {
                    self.local(*id)
                }
            }
            ValueKind::Field(b, i) => format!("({}).m{i}", self.read_place(b)),
            ValueKind::SharedField(b, i) => format!("(*({}).m{i})", self.read_place(b)),
            ValueKind::Index(b, i) => {
                let elem_is_ref = match b.ty {
                    Type::Array(a) => TABLES.with(|t| {
                        matches!(
                            t.borrow().0[a].elem,
                            Type::SharedField(_) | Type::MutField(_)
                        )
                    }),
                    Type::List(l) => TABLES.with(|t| {
                        matches!(t.borrow().2[l], Type::SharedField(_) | Type::MutField(_))
                    }),
                    _ => false,
                };
                if elem_is_ref && !matches!(v.ty, Type::SharedField(_) | Type::MutField(_)) {
                    format!(
                        "(*(*l_at(&({}), {}, {}, {})))",
                        self.collection(b),
                        self.value(i),
                        v.span.line,
                        v.span.column
                    )
                } else {
                    format!(
                        "(*l_at(&({}), {}, {}, {}))",
                        self.collection(b),
                        self.value(i),
                        v.span.line,
                        v.span.column
                    )
                }
            }
            _ => format!("({})", self.value(v)),
        }
    }
    /// Mutable place expression for an element or field target.
    fn write_place(&self, v: &Value) -> String {
        match &v.kind {
            ValueKind::Local(id) => {
                if matches!(v.ty, Type::SharedField(_) | Type::MutField(_)) {
                    format!("v{id}")
                } else {
                    self.local(*id)
                }
            }
            ValueKind::Field(b, i) => format!("({}).m{i}", self.write_place(b)),
            ValueKind::Index(b, i) => format!(
                "(*l_at_mut(&mut ({}), {}, {}, {}))",
                self.write_place(b),
                self.value(i),
                v.span.line,
                v.span.column
            ),
            _ => unreachable!("store target is a place"),
        }
    }
    /// A collection expression: its place, or a temporary value.
    fn collection(&self, v: &Value) -> String {
        if is_place(v) {
            self.read_place(v)
        } else {
            format!("{{ {} }}", self.value(v))
        }
    }
    fn local(&self, id: usize) -> String {
        if self.refs.borrow().contains(&id) {
            format!("(*v{id})")
        } else {
            format!("v{id}")
        }
    }
    fn place(&self, place: &Place) -> String {
        let mut out = self.local(place.root);
        for field in &place.fields {
            out.push_str(&format!(".m{field}"));
        }
        out
    }
    fn is_mut_field_place(&self, place: &Place) -> bool {
        let Some(mut current) = self.local_types.borrow().get(&place.root).copied() else {
            return false;
        };
        for &f in &place.fields {
            match current {
                Type::Struct(sid) => {
                    current = self.program.structs[sid].fields[f].1;
                }
                _ => return false,
            }
        }
        matches!(current, Type::MutField(_))
    }
    /// Evaluate index expressions before creating the borrow, like CFG lowering.
    fn loan_place(&self, v: &Value, mutable: bool, indices: &mut Vec<String>) -> String {
        match &v.kind {
            ValueKind::Local(id) => {
                if matches!(v.ty, Type::SharedField(_) | Type::MutField(_)) {
                    format!("v{id}")
                } else {
                    self.local(*id)
                }
            }
            ValueKind::Field(base, field) => {
                format!("({}).m{field}", self.loan_place(base, mutable, indices))
            }
            ValueKind::Index(base, index) => {
                let base = self.loan_place(base, mutable, indices);
                let i = indices.len();
                indices.push(self.value(index));
                let (at, borrow) = if mutable {
                    ("l_at_mut", "&mut")
                } else {
                    ("l_at", "&")
                };
                format!(
                    "(*{at}({borrow} ({base}), l_idx{i}, {}, {}))",
                    v.span.line, v.span.column
                )
            }
            _ => unreachable!("local reference origin is a place"),
        }
    }
    /// Evaluates arguments left to right into temporaries before the call, so a
    /// receiver borrow starts only after every argument has been evaluated.
    fn call_with_receiver(&self, func: usize, receiver: &str, args: &[Value]) -> String {
        let mut code = String::from("{ ");
        let mut names = vec![receiver.to_string()];
        for (i, arg) in args.iter().enumerate() {
            let value = self.value(arg);
            if matches!(arg.kind, ValueKind::Borrow(..)) {
                names.push(value);
            } else {
                code.push_str(&format!("let l_a{i} = {value}; "));
                names.push(format!("l_a{i}"));
            }
        }
        code.push_str(&format!("f{func}({}) }}", names.join(", ")));
        code
    }
    fn value(&self, v: &Value) -> String {
        match &v.kind {
            ValueKind::StoredBorrow(source) => {
                let exclusive = matches!(v.ty, Type::MutField(_));
                let mode = if exclusive {
                    Receiver::Exclusive
                } else {
                    Receiver::Shared
                };
                let expr = self.borrow_expression(source, mode);
                if exclusive {
                    format!("unsafe {{ &mut *({expr} as *mut _) }}")
                } else {
                    format!("unsafe {{ &*({expr} as *const _) }}")
                }
            }
            ValueKind::SharedField(..) => self.read_place(v),
            ValueKind::Int(n) => format!("{n}i64"),
            ValueKind::Float(n) => {
                if v.ty == Type::F32 {
                    format!("f32::from_bits({}u32)", (*n as f32).to_bits())
                } else {
                    format!("f64::from_bits({}u64)", n.to_bits())
                }
            }
            ValueKind::ArrayLit(items) => {
                let items: Vec<String> = items.iter().map(|x| self.value(x)).collect();
                format!("[{}]", items.join(", "))
            }
            ValueKind::ListLit(items) => {
                let mut code = format!("{{ let mut l_v = Vec::with_capacity({}); ", items.len());
                for x in items {
                    code.push_str(&format!("l_v.push({}); ", self.value(x)));
                }
                code.push_str("l_v }");
                code
            }
            ValueKind::Index(..) => self.read_place(v),
            ValueKind::Length(b) if b.ty == Type::Text => {
                format!("(({}).0.len() as i64)", self.read_place(b))
            }
            ValueKind::Length(b) => format!("(({}).len() as i64)", self.collection(b)),
            ValueKind::TextByte(base, index) => format!(
                "i64::from(*l_at(({}).0.as_bytes(), {}, {}, {}))",
                self.read_place(base),
                self.value(index),
                v.span.line,
                v.span.column
            ),
            ValueKind::Capacity(b) => format!("(({}).capacity() as i64)", self.collection(b)),
            ValueKind::ListPush(list, item) if matches!(list.ty, Type::RegionList(..)) => format!(
                "{{ let l_x = {}; ({}).push(l_x, {}, {}) }}",
                self.value(item),
                self.write_place(list),
                v.span.line,
                v.span.column
            ),
            ValueKind::ListReserve(list, n) if matches!(list.ty, Type::RegionList(..)) => format!(
                "{{ let l_n = {}; ({}).reserve(l_n, 0, {}, {}) }}",
                self.value(n),
                self.write_place(list),
                v.span.line,
                v.span.column
            ),
            ValueKind::ListPush(list, item) => format!(
                "{{ let l_x = {}; l_push(&mut ({}), l_x) }}",
                self.value(item),
                self.write_place(list)
            ),
            ValueKind::ListReserve(list, n) => format!(
                "{{ let l_n = {}; l_reserve(&mut ({}), l_n, {}, {}) }}",
                self.value(n),
                self.write_place(list),
                v.span.line,
                v.span.column
            ),
            ValueKind::ListPop(list, option, some, none) => format!(
                "match ({}).pop() {{ Some(l_x) => E{option}::V{some}(l_x), None => E{option}::V{none} }}",
                self.write_place(list)
            ),
            ValueKind::RegionList(region) => {
                format!("LRegionList::new(&{})", self.place(region))
            }
            // Rust's futures are lazy and poll-based, like L's: the
            // reference backend reuses them instead of a second state machine.
            ValueKind::Await(future) => format!("({}).await", self.value(future)),
            ValueKind::JoinAll(group) => format!("l_join_all({}).await", self.value(group)),
            ValueKind::Join(handles) => {
                let Type::Struct(pair) = v.ty else {
                    unreachable!("el resultado de join es un struct")
                };
                format!(
                    "{{ let (l_first, l_second) = l_join({}, {}).await; S{pair} {{ m0: l_first, m1: l_second }} }}",
                    self.value(&handles[0]),
                    self.value(&handles[1]),
                )
            }
            // Registering the task in the scheduler; the handle owns it.
            ValueKind::Spawn(future) => format!("l_spawn({})", self.value(future)),
            ValueKind::RegionNew => "LRegion::new()".into(),
            ValueKind::RegionBytes(region, size) => format!(
                "{}.bytes({}, {}, {})",
                self.place(region),
                self.value(size),
                v.span.line,
                v.span.column
            ),
            ValueKind::BytesLen(buffer) => format!("(({}).1 as i64)", self.place(buffer)),
            ValueKind::BytesGet(buffer, index) => format!(
                "l_bytes_get(&{}, {}, {}, {})",
                self.place(buffer),
                self.value(index),
                v.span.line,
                v.span.column
            ),
            ValueKind::BytesSet(buffer, index, byte) => format!(
                "l_bytes_set(&{}, {}, {}, {}, {})",
                self.place(buffer),
                self.value(index),
                self.value(byte),
                v.span.line,
                v.span.column
            ),
            ValueKind::Convert(val, target) => {
                format!("(({}) as {})", self.value(val), ty(*target))
            }
            ValueKind::Bool(b) => b.to_string(),
            ValueKind::Text(s) => format!("LText(std::borrow::Cow::Borrowed({s:?}))"),
            ValueKind::Interpolate(parts) => {
                let capacity: usize = parts
                    .iter()
                    .filter_map(|p| match &p.kind {
                        ValueKind::Text(s) => Some(s.len()),
                        _ => None,
                    })
                    .sum();
                let mut code = format!("{{ let mut l_text = String::with_capacity({capacity});\n");
                for part in parts {
                    if let ValueKind::Text(s) = &part.kind {
                        code.push_str(&format!("l_text.push_str({s:?});\n"));
                    } else {
                        code.push_str(&format!("l_write(&mut l_text, &({}));\n", self.value(part)));
                    }
                }
                code.push_str("LText(std::borrow::Cow::Owned(l_text)) }");
                code
            }
            ValueKind::Unit => "()".into(),
            ValueKind::Local(id) => {
                if matches!(v.ty, Type::SharedField(_) | Type::MutField(_)) {
                    format!("v{id}")
                } else {
                    self.local(*id)
                }
            }
            ValueKind::Call(id, args)
                if self.program.functions[*id].name == crate::lir::SLEEP_MS =>
            {
                format!(
                    "Box::pin(f{id}(l_check_sleep({}, {}, {})))",
                    self.value(&args[0]),
                    v.span.line,
                    v.span.column
                )
            }
            ValueKind::Call(id, args)
                if args.iter().any(|a| matches!(a.kind, ValueKind::Borrow(..))) =>
            {
                let mut prefix = String::from("{ ");
                let mut actual = Vec::new();
                for (i, arg) in args.iter().enumerate() {
                    let code = self.value(arg);
                    if matches!(arg.kind, ValueKind::Borrow(..)) {
                        actual.push(code);
                    } else {
                        prefix.push_str(&format!("let l_arg{i} = {code}; "));
                        actual.push(format!("l_arg{i}"));
                    }
                }
                let call = format!("{prefix}f{id}({}) }}", actual.join(","));
                if self.program.functions[*id].is_async {
                    format!("Box::pin({call})")
                } else {
                    call
                }
            }
            ValueKind::Call(id, args) => {
                let call = format!(
                    "f{id}({})",
                    args.iter()
                        .map(|a| self.value(a))
                        .collect::<Vec<_>>()
                        .join(",")
                );
                if self.program.functions[*id].is_async {
                    format!("Box::pin({call})")
                } else {
                    call
                }
            }
            ValueKind::Borrow(p, exclusive) => {
                let borrow = if *exclusive { "&mut " } else { "&" };
                format!("{borrow}{}", self.place(p))
            }
            ValueKind::MethodCall(id, place, receiver, args) => {
                let borrow = match receiver {
                    Receiver::Shared => "&",
                    Receiver::Exclusive => "&mut ",
                };
                // Receiver places have no side effects: borrowing after the
                // arguments preserves left-to-right evaluation.
                self.call_with_receiver(*id, &format!("{borrow}{}", self.place(place)), args)
            }
            ValueKind::TempMethodCall(id, receiver, args) => {
                format!(
                    "{{ let l_recv = {}; {} }}",
                    self.value(receiver),
                    self.call_with_receiver(*id, "&l_recv", args)
                )
            }
            ValueKind::Construct(id, inits) => {
                // Rust evaluates struct expression fields in written order, which is
                // the LIR evaluation order.
                let fields = inits
                    .iter()
                    .map(|(index, value)| format!("m{index}: {}", self.value(value)))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("S{id} {{ {fields} }}")
            }
            ValueKind::Variant(id, variant, payload) => {
                if payload.is_empty() {
                    format!("E{id}::V{variant}")
                } else {
                    let args: Vec<String> = payload.iter().map(|p| self.value(p)).collect();
                    format!("E{id}::V{variant}({})", args.join(", "))
                }
            }
            ValueKind::Match(scrutinee, arms) => self.match_value(scrutinee, arms),
            ValueKind::Field(base, index) => format!("({}).m{index}", self.value(base)),
            ValueKind::Platform(op, args) => match op {
                PlatformOp::ArgCount => "l_process_arg_count()".into(),
                PlatformOp::PrintError => {
                    format!("l_print_error(&({}))", self.read_place(&args[0]))
                }
                PlatformOp::WriteBytes => {
                    format!(
                        "l_write_bytes(&({}), &({}))",
                        self.read_place(&args[0]),
                        self.value(&args[1])
                    )
                }
                PlatformOp::SameFile => {
                    format!(
                        "l_same_file(&({}), &({}))",
                        self.read_place(&args[0]),
                        self.read_place(&args[1])
                    )
                }
                PlatformOp::Arg | PlatformOp::ReadText => {
                    let call = if *op == PlatformOp::Arg {
                        format!("l_process_arg({})", self.value(&args[0]))
                    } else {
                        format!(
                            "l_read_text(&({}), {})",
                            self.read_place(&args[0]),
                            self.value(&args[1])
                        )
                    };
                    let Type::Enum(id) = v.ty else {
                        unreachable!("platform result")
                    };
                    format!(
                        "match {call} {{ Ok(value) => E{id}::V0(value), Err(code) => E{id}::V1(code) }}"
                    )
                }
            },
            ValueKind::Print(a) => format!("println!(\"{{}}\", {})", self.value(a)),
            ValueKind::Unary(op, a) if op == "-" && a.ty == Type::Int => format!(
                "l_checked(({}).checked_neg(), {}, {})",
                self.value(a),
                v.span.line,
                v.span.column
            ),
            ValueKind::Unary(op, a) => format!("({op}({}))", self.value(a)),
            ValueKind::Binary(op, a, b) => {
                let method = match op.as_str() {
                    "+" => Some("checked_add"),
                    "-" => Some("checked_sub"),
                    "*" => Some("checked_mul"),
                    "/" => Some("checked_div"),
                    "%" => Some("checked_rem"),
                    _ => None,
                };
                if let Some(method) = method.filter(|_| a.ty == Type::Int) {
                    format!(
                        "l_checked(({}).{method}({}), {}, {})",
                        self.value(a),
                        self.value(b),
                        v.span.line,
                        v.span.column
                    )
                } else {
                    format!("(({}) {op} ({}))", self.value(a), self.value(b))
                }
            }
        }
    }
    fn match_value(&self, scrutinee: &Value, arms: &[Arm]) -> String {
        let mut out = format!("match {} {{\n", self.value(scrutinee));
        for arm in arms {
            for (id, t) in &arm.bindings {
                self.local_types.borrow_mut().insert(*id, *t);
                if matches!(t, Type::SharedField(_) | Type::MutField(_))
                    || (t.is_move() && !self.by_value.contains(id))
                {
                    self.refs.borrow_mut().insert(*id);
                }
            }
            let mut guards = Vec::new();
            let pattern = self.pattern(&arm.pattern, &mut guards);
            let guard = if guards.is_empty() {
                String::new()
            } else {
                format!(" if {}", guards.join(" && "))
            };
            let mut body = self.block(&arm.body);
            body.pop(); // closing brace
            if let Some(v) = &arm.value {
                body.push_str(&self.value(v));
                body.push('\n');
            }
            body.push('}');
            out.push_str(&format!("{pattern}{guard} => {body}\n"));
        }
        out.push('}');
        out
    }
    fn pattern(&self, p: &Pattern, guards: &mut Vec<String>) -> String {
        match p {
            Pattern::Wild => "_".into(),
            Pattern::Bind(id) => {
                let is_field_ref = self
                    .local_types
                    .borrow()
                    .get(id)
                    .is_some_and(|t| matches!(t, Type::SharedField(_) | Type::MutField(_)));
                if is_field_ref {
                    let is_mut = self
                        .local_types
                        .borrow()
                        .get(id)
                        .is_some_and(|t| matches!(t, Type::MutField(_)));
                    if is_mut {
                        format!("mut v{id}")
                    } else {
                        format!("v{id}")
                    }
                } else if self.refs.borrow().contains(id) {
                    format!("ref v{id}")
                } else {
                    format!("v{id}")
                }
            }
            Pattern::Int(n) => format!("{n}i64"),
            Pattern::Bool(b) => b.to_string(),
            Pattern::Text(s) => {
                // Text is not a Rust literal pattern: bind by reference and compare.
                let n = self.temps.get();
                self.temps.set(n + 1);
                guards.push(format!("l_p{n}.0.as_ref() == {s:?}"));
                format!("ref l_p{n}")
            }
            Pattern::Variant(id, variant, subs) => {
                if subs.is_empty() {
                    format!("E{id}::V{variant}")
                } else {
                    let subs: Vec<String> = subs.iter().map(|s| self.pattern(s, guards)).collect();
                    format!("E{id}::V{variant}({})", subs.join(", "))
                }
            }
        }
    }
    fn borrow_expression(&self, value: &Value, mode: Receiver) -> String {
        if matches!(value.kind, ValueKind::Call(..) | ValueKind::MethodCall(..)) {
            return self.value(value);
        }
        let mutable = mode == Receiver::Exclusive;
        let borrow = if mutable { "&mut " } else { "&" };
        let mut indices = Vec::new();
        let origin = self.loan_place(value, mutable, &mut indices);
        let indices = indices
            .iter()
            .enumerate()
            .map(|(i, code)| format!("let l_idx{i} = {code}; "))
            .collect::<String>();
        format!("{{ {indices}{borrow}({origin}) }}")
    }
    fn block(&self, body: &[Instruction]) -> String {
        let mut out = String::from("{\n");
        for ins in body {
            out.push_str(&match ins {
                Instruction::BindRef(id, mode, referent, place) => {
                    self.local_types.borrow_mut().insert(*id, *referent);
                    let value = self.borrow_expression(place, *mode);
                    self.refs.borrow_mut().insert(*id);
                    let annotation = if matches!(referent, Type::Slice(_)) {
                        format!(": {}{}", borrow_prefix(*mode, false), ty(*referent))
                    } else {
                        String::new()
                    };
                    format!("let v{id}{annotation} = {value};\n")
                }
                Instruction::Bind(id, mutable, v) => {
                    self.local_types.borrow_mut().insert(*id, v.ty);
                    let has_lt = match v.ty {
                        Type::SharedField(_) | Type::MutField(_) => true,
                        Type::Struct(s) => LIFETIMES.with(|l| l.borrow().0.contains(&s)),
                        Type::Enum(e) => LIFETIMES.with(|l| l.borrow().1.contains(&e)),
                        Type::Array(a) => TABLES.with(|tbl| {
                            matches!(
                                tbl.borrow().0[a].elem,
                                Type::SharedField(_) | Type::MutField(_)
                            )
                        }),
                        Type::List(l) | Type::RegionList(l, _) => TABLES.with(|tbl| {
                            matches!(tbl.borrow().2[l], Type::SharedField(_) | Type::MutField(_))
                        }),
                        _ => false,
                    };
                    if has_lt {
                        format!(
                            "let {}v{id} = {};\n",
                            if *mutable { "mut " } else { "" },
                            self.value(v)
                        )
                    } else {
                        format!(
                            "let {}v{id}: {} = {};\n",
                            if *mutable { "mut " } else { "" },
                            ty(v.ty),
                            self.value(v)
                        )
                    }
                }
                Instruction::Store(place, v) => {
                    if !place.fields.is_empty() && self.is_mut_field_place(place) {
                        format!("(*{}) = {};\n", self.place(place), self.value(v))
                    } else {
                        format!("{} = {};\n", self.place(place), self.value(v))
                    }
                }
                Instruction::Eval(v) => format!("{};\n", self.value(v)),
                Instruction::ReturnRef(mode, v) => format!("return {};\n", self.borrow_expression(v, *mode)),
                Instruction::Return(v) => format!("return {};\n", self.value(v)),
                Instruction::If(v, yes, no) => {
                    format!(
                        "if {} {} else {}\n",
                        self.value(v),
                        self.block(yes),
                        self.block(no)
                    )
                }
                Instruction::While(v, b) => {
                    format!("while {} {}\n", self.value(v), self.block(b))
                }
                Instruction::ForRange(id, start, end, inclusive, b) => format!(
                    "{{ let l_start: i64 = {}; let l_end: i64 = {}; for v{id} in l_start..{}l_end {} }}\n",
                    self.value(start),
                    self.value(end),
                    if *inclusive { "=" } else { "" },
                    self.block(b)
                ),
                Instruction::ForEach(id, by_ref, coll, b) => {
                    // Copy elements are copied; owned ones are borrowed.
                    let elem_is_ref = match coll.ty {
                        Type::Array(a) => TABLES.with(|t| {
                            matches!(
                                t.borrow().0[a].elem,
                                Type::SharedField(_) | Type::MutField(_)
                            )
                        }),
                        Type::List(l) => TABLES.with(|t| {
                            matches!(t.borrow().2[l], Type::SharedField(_) | Type::MutField(_))
                        }),
                        _ => false,
                    };
                    if *by_ref || elem_is_ref {
                        self.refs.borrow_mut().insert(*id);
                    }
                    format!(
                        "for v{id} in ({}).iter(){} {}\n",
                        self.collection(coll),
                        if *by_ref { "" } else { ".copied()" },
                        self.block(b)
                    )
                }
                Instruction::StoreElem(target, v) => format!(
                    "{{ let l_v = {}; {} = l_v; }}\n",
                    self.value(v),
                    self.write_place(target)
                ),
                Instruction::Yield => "l_yield().await;\n".into(),
                Instruction::Sleep(ms) => format!("l_sleep({}).await;\n", self.value(ms)),
                Instruction::Loop(b) => format!("loop {}\n", self.block(b)),
                Instruction::Break => "break;\n".into(),
                Instruction::Continue => "continue;\n".into(),
                Instruction::Block(b) => format!("{}\n", self.block(b)),
            });
        }
        out.push('}');
        out
    }
}

pub fn emit(program: &Program) -> String {
    TABLES.with(|t| {
        *t.borrow_mut() = (
            program.arrays.clone(),
            program.slices.clone(),
            program.lists.clone(),
            program.task_groups.clone(),
            program.futures.clone(),
        )
    });
    let mut lifetime_structs = BTreeSet::new();
    let mut lifetime_enums = BTreeSet::new();
    loop {
        let mut changed = false;
        for (id, s) in program.structs.iter().enumerate() {
            if !lifetime_structs.contains(&id) {
                let has = s.fields.iter().any(|(_, t)| match t {
                    Type::SharedField(_) | Type::MutField(_) => true,
                    Type::Struct(s) => lifetime_structs.contains(s),
                    Type::Enum(e) => lifetime_enums.contains(e),
                    _ => false,
                });
                if has {
                    lifetime_structs.insert(id);
                    changed = true;
                }
            }
        }
        for (id, e) in program.enums.iter().enumerate() {
            if !lifetime_enums.contains(&id) {
                let has = e.variants.iter().any(|(_, p)| {
                    p.iter().any(|t| match t {
                        Type::SharedField(_) | Type::MutField(_) => true,
                        Type::Struct(s) => lifetime_structs.contains(s),
                        Type::Enum(e) => lifetime_enums.contains(e),
                        _ => false,
                    })
                });
                if has {
                    lifetime_enums.insert(id);
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    LIFETIMES.with(|l| *l.borrow_mut() = (lifetime_structs.clone(), lifetime_enums.clone()));
    let mut out = String::from("#![allow(unused, unused_parens, unconditional_panic)]\n");
    out.push_str("struct LText(std::borrow::Cow<'static, str>);\nimpl std::fmt::Display for LText { fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(self.0.as_ref()) } }\n");
    out.push_str(include_str!("platform_contract.inc.rs"));
    out.push_str(include_str!("backend/platform_runtime.inc.rs"));
    out.push_str("fn l_write<T: std::fmt::Display>(out: &mut String, value: &T) { use std::fmt::Write; if write!(out, \"{value}\").is_err() { panic!(\"falló formato Text\"); } }\n");
    // Regions: every buffer is a separate zeroed allocation owned by the region
    // (observably equivalent to the native bump allocator); dropping the region
    // frees all of them. Buffers are raw views kept valid by L's region rules.
    out.push_str("fn l_panic(line: usize, column: usize, msg: &str) -> ! { eprintln!(\"ELE {line}:{column}: {msg}\"); std::process::abort() }\n");
    out.push_str(include_str!("backend/region_runtime.inc.rs"));
    out.push_str(&format!(
        "const L_MAX_SLEEP_MS: i64 = {};\n",
        crate::lir::MAX_SLEEP_MS
    ));
    out.push_str(include_str!("backend/timer_runtime.inc.rs"));
    out.push_str(include_str!("backend/async_runtime.inc.rs"));
    out.push_str("#[derive(Clone, Copy)] struct LBytes(*mut u8, usize);\n");
    out.push_str("fn l_bytes_get(b: &LBytes, i: i64, line: usize, column: usize) -> i64 { if i < 0 || i as usize >= b.1 { l_panic(line, column, \"índice de buffer fuera de rango\") } unsafe { *b.0.add(i as usize) as i64 } }\n");
    out.push_str("fn l_bytes_set(b: &LBytes, i: i64, v: i64, line: usize, column: usize) { if i < 0 || i as usize >= b.1 { l_panic(line, column, \"índice de buffer fuera de rango\") } if !(0..=255).contains(&v) { l_panic(line, column, \"valor de byte fuera de rango (0..=255)\") } unsafe { *b.0.add(i as usize) = v as u8 } }\n");
    // Collections: bounds-checked element access and the list capacity policy
    // shared with the native backend (literal: exact; push: max(4, 2*cap);
    // reserve(n): max(len + n, 2*cap)).
    out.push_str("fn l_at<T>(s: &[T], i: i64, line: usize, column: usize) -> &T { if i < 0 || i as usize >= s.len() { l_panic(line, column, \"índice fuera de rango\") } &s[i as usize] }\n");
    out.push_str("fn l_at_mut<T>(s: &mut [T], i: i64, line: usize, column: usize) -> &mut T { if i < 0 || i as usize >= s.len() { l_panic(line, column, \"índice fuera de rango\") } &mut s[i as usize] }\n");
    out.push_str("fn l_push<T>(v: &mut Vec<T>, x: T) { if v.len() == v.capacity() { let cap = std::cmp::max(4, v.capacity() * 2); v.reserve_exact(cap - v.len()); } v.push(x) }\n");
    // Same checked arithmetic as the native runtime: counts and byte sizes
    // above i64::MAX are a located panic, not a Rust `capacity overflow`.
    out.push_str("fn l_reserve<T>(v: &mut Vec<T>, n: i64, line: usize, column: usize) { if n < 0 { l_panic(line, column, \"reserve con tamaño negativo\") } let (len, cap) = (v.len() as i64, v.capacity() as i64); if cap - len >= n { return } let need = len.checked_add(n); let double = cap.checked_mul(2); let new = match need { Some(need) => std::cmp::max(need, double.unwrap_or(need)), None => l_panic(line, column, \"capacidad de List desbordada\") }; if new.checked_mul(std::cmp::max(std::mem::size_of::<T>(), 1) as i64).is_none() { l_panic(line, column, \"capacidad de List desbordada\") } v.reserve_exact((new - len) as usize); }\n");
    out.push_str("fn l_checked(v: Option<i64>, line: usize, column: usize) -> i64 { match v { Some(n) => n, None => { eprintln!(\"ELE {line}:{column}: overflow entero o división/resto por cero\"); std::process::abort() } } }\n");
    for (id, s) in program.structs.iter().enumerate() {
        let fields = s
            .fields
            .iter()
            .enumerate()
            .map(|(i, (_, t))| format!("m{i}: {}", ty(*t)))
            .collect::<Vec<_>>()
            .join(", ");
        let lifetime = if lifetime_structs.contains(&id) {
            "<'l>"
        } else {
            ""
        };
        out.push_str(&format!("struct S{id}{lifetime} {{ {fields} }}\n"));
    }
    // Enums: the discriminant of `V{i}` is its LIR variant index.
    for (id, e) in program.enums.iter().enumerate() {
        let lifetime = if lifetime_enums.contains(&id) {
            "<'l>"
        } else {
            ""
        };
        let variants = e
            .variants
            .iter()
            .enumerate()
            .map(|(i, (_, payload))| {
                if payload.is_empty() {
                    format!("V{i}")
                } else {
                    let types: Vec<String> = payload.iter().map(|t| ty(*t)).collect();
                    format!("V{i}({})", types.join(", "))
                }
            })
            .collect::<Vec<_>>()
            .join(", ");
        out.push_str(&format!("enum E{id}{lifetime} {{ {variants} }}\n"));
    }
    for (id, f) in program.functions.iter().enumerate() {
        let mut local_types = HashMap::new();
        if let Some((self_id, owner, _)) = f.receiver {
            local_types.insert(self_id, owner);
        }
        for (param_id, t) in &f.params {
            local_types.insert(*param_id, *t);
        }
        let emitter = Emitter {
            program,
            refs: RefCell::new(HashSet::new()),
            by_value: &f.by_value_bindings,
            temps: Cell::new(0),
            local_types: RefCell::new(local_types),
        };
        let mut params = Vec::new();
        let has_lifetime_arg = f.params.iter().any(|(_, t)| match t {
            Type::SharedField(_) | Type::MutField(_) => true,
            Type::Struct(s) => lifetime_structs.contains(s),
            Type::Enum(e) => lifetime_enums.contains(e),
            Type::Array(a) => TABLES.with(|tbl| {
                matches!(
                    tbl.borrow().0[*a].elem,
                    Type::SharedField(_) | Type::MutField(_)
                )
            }),
            Type::List(l) => TABLES
                .with(|tbl| matches!(tbl.borrow().2[*l], Type::SharedField(_) | Type::MutField(_))),
            _ => false,
        });
        let has_lifetime_res = match f.result {
            Type::SharedField(_) | Type::MutField(_) => true,
            Type::Struct(s) => lifetime_structs.contains(&s),
            Type::Enum(e) => lifetime_enums.contains(&e),
            Type::Array(a) => TABLES.with(|tbl| {
                matches!(
                    tbl.borrow().0[a].elem,
                    Type::SharedField(_) | Type::MutField(_)
                )
            }),
            Type::List(l) => TABLES
                .with(|tbl| matches!(tbl.borrow().2[l], Type::SharedField(_) | Type::MutField(_))),
            _ => false,
        };
        let has_lifetime_receiver = f
            .receiver
            .as_ref()
            .is_some_and(|(_, owner, _)| match owner {
                Type::Struct(s) => lifetime_structs.contains(s),
                Type::Enum(e) => lifetime_enums.contains(e),
                _ => false,
            });
        let needs_lifetime = f.borrow_return.is_some()
            || f.view_return.is_some()
            || has_lifetime_arg
            || has_lifetime_res
            || has_lifetime_receiver;
        let lifetime = if needs_lifetime { "<'l>" } else { "" };
        if let Some((self_id, owner, receiver)) = f.receiver {
            emitter.refs.borrow_mut().insert(self_id);
            let borrow = borrow_prefix(
                receiver,
                f.borrow_return
                    .as_ref()
                    .is_some_and(|r| r.params.contains(&0)),
            );
            let owner_name = ty(owner);
            params.push(format!("v{self_id}: {borrow}{owner_name}"));
        }
        for (i, (id, t)) in f.params.iter().enumerate() {
            let borrow = if let Some(mode) = f.param_modes[i] {
                emitter.refs.borrow_mut().insert(*id);
                borrow_prefix(
                    mode,
                    f.borrow_return.as_ref().is_some_and(|r| {
                        r.params.contains(&(i + usize::from(f.receiver.is_some())))
                    }),
                )
            } else {
                ""
            };
            params.push(format!("v{id}: {borrow}{}", ty(*t)));
        }
        let (lifetime, result) = if let Some(r) = &f.borrow_return {
            (
                "<'l>",
                format!("{}{}", borrow_prefix(r.mode, true), ty(f.result)),
            )
        } else {
            (lifetime, ty(f.result))
        };
        out.push_str(&format!(
            "{}fn f{id}{lifetime}({}) -> {result} {}\n",
            if f.is_async { "async " } else { "" },
            params.join(","),
            emitter.block(&f.body)
        ));
    }
    // An async main runs on the cooperative executor; a sync main is called.
    if program.functions[program.main].is_async {
        out.push_str(&format!(
            "fn main() {{ l_run_main(f{}()); }}\n",
            program.main
        ));
    } else if program.functions[program.main].result == Type::Int {
        out.push_str(&format!(
            "fn main() -> std::process::ExitCode {{ std::process::ExitCode::from(u8::try_from(f{}()).unwrap_or(255)) }}\n",
            program.main
        ));
    } else {
        out.push_str(&format!("fn main() {{ f{}(); }}\n", program.main));
    }
    out
}
