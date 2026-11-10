//! Target layout, independent of Cranelift. This is L's internal ABI, not C ABI.
use crate::lir::{ArrayDef, EnumDef, StructDef, Type};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Component {
    pub ty: Type,
    pub offset: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    pub size: u32,
    pub align: u32,
    pub fields: Vec<u32>,
    /// Scalar representation used for registers and explicit memory transfers.
    pub components: Vec<Component>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VariantLayout {
    pub fields: Vec<u32>,
    pub size: u32,
    pub align: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnumLayout {
    pub layout: Layout,
    pub variants: Vec<VariantLayout>,
}

#[derive(Debug, Clone)]
pub struct Layouts {
    structs: Vec<Layout>,
    enums: Vec<EnumLayout>,
    arrays: Vec<Layout>,
}

/// Most scalar components a value may have in the native backend (values are
/// flattened into SSA variables and call arguments).
pub const MAX_COMPONENTS: usize = 4096;

/// `len` elements of `elem` laid out contiguously.
fn array_layout(elem: &Layout, len: usize) -> Result<Layout, String> {
    let count = elem
        .components
        .len()
        .checked_mul(len)
        .filter(|n| *n <= MAX_COMPONENTS)
        .ok_or("array excede 4096 componentes nativos; use List<T> o --backend rustc")?;
    let size = u32::try_from(len)
        .ok()
        .and_then(|n| n.checked_mul(elem.size))
        .filter(|n| *n <= i32::MAX as u32)
        .ok_or("array excede el rango de offsets nativos")?;
    let mut components = Vec::with_capacity(count);
    for i in 0..len as u32 {
        for c in &elem.components {
            components.push(Component {
                ty: c.ty,
                offset: i * elem.size + c.offset,
            });
        }
    }
    Ok(Layout {
        size,
        align: elem.align,
        fields: Vec::new(),
        components,
    })
}

fn round(n: u32, align: u32) -> Result<u32, String> {
    n.checked_add(align - 1)
        .map(|n| n & !(align - 1))
        .ok_or_else(|| "layout excede 32 bits".into())
}

impl Layouts {
    /// Windows x86-64: pointer/i64/f64 align 8, Bool align 1, Text 3 words.
    pub fn windows_x64(struct_defs: &[StructDef], enum_defs: &[EnumDef]) -> Result<Self, String> {
        Self::windows_x64_with(struct_defs, enum_defs, &[])
    }

    /// Layouts including fixed-size arrays: `[T; N]` is `N` elements of
    /// stride `size_of(T)` (sizes are already multiples of the alignment),
    /// aligned like `T`. A `List<T>` is three words `(ptr, len, cap)` and a
    /// slice view `(ptr, len)`; neither depends on the layout of `T`.
    pub fn windows_x64_with(
        struct_defs: &[StructDef],
        enum_defs: &[EnumDef],
        array_defs: &[ArrayDef],
    ) -> Result<Self, String> {
        let mut struct_cache = vec![None; struct_defs.len()];
        let mut struct_active = vec![false; struct_defs.len()];
        let mut enum_cache = vec![None; enum_defs.len()];
        let mut enum_active = vec![false; enum_defs.len()];

        #[allow(clippy::too_many_arguments)]
        fn resolve_type(
            ty: Type,
            struct_defs: &[StructDef],
            enum_defs: &[EnumDef],
            array_defs: &[ArrayDef],
            struct_cache: &mut [Option<Layout>],
            struct_active: &mut [bool],
            enum_cache: &mut [Option<EnumLayout>],
            enum_active: &mut [bool],
        ) -> Result<Layout, String> {
            match ty {
                Type::Struct(s) => resolve_struct(
                    s,
                    struct_defs,
                    enum_defs,
                    array_defs,
                    struct_cache,
                    struct_active,
                    enum_cache,
                    enum_active,
                ),
                Type::Enum(e) => resolve_enum(
                    e,
                    struct_defs,
                    enum_defs,
                    array_defs,
                    struct_cache,
                    struct_active,
                    enum_cache,
                    enum_active,
                )
                .map(|el| el.layout),
                Type::Array(a) => {
                    let def = array_defs.get(a).ok_or("array inexistente en layout")?;
                    let elem = resolve_type(
                        def.elem,
                        struct_defs,
                        enum_defs,
                        array_defs,
                        struct_cache,
                        struct_active,
                        enum_cache,
                        enum_active,
                    )?;
                    array_layout(&elem, def.len)
                }
                _ => Layouts::primitive(ty),
            }
        }

        #[allow(clippy::too_many_arguments)]
        fn resolve_struct(
            id: usize,
            struct_defs: &[StructDef],
            enum_defs: &[EnumDef],
            array_defs: &[ArrayDef],
            struct_cache: &mut [Option<Layout>],
            struct_active: &mut [bool],
            enum_cache: &mut [Option<EnumLayout>],
            enum_active: &mut [bool],
        ) -> Result<Layout, String> {
            if id >= struct_defs.len() {
                return Err("struct inexistente en layout".into());
            }
            if let Some(layout) = &struct_cache[id] {
                return Ok(layout.clone());
            }
            if std::mem::replace(&mut struct_active[id], true) {
                return Err("struct recursivo por valor".into());
            }
            let mut result = Layout {
                size: 0,
                align: 1,
                fields: Vec::new(),
                components: Vec::new(),
            };
            for (_, ty) in &struct_defs[id].fields {
                let field = resolve_type(
                    *ty,
                    struct_defs,
                    enum_defs,
                    array_defs,
                    struct_cache,
                    struct_active,
                    enum_cache,
                    enum_active,
                )?;
                result.align = result.align.max(field.align);
                let offset = round(result.size, field.align)?;
                result.fields.push(offset);
                // SSA flattening must not expand a small, deeply nested source
                // exponentially until the compiler runs out of memory.
                if result.components.len() + field.components.len() > 4096 {
                    return Err(
                        "struct excede 4096 componentes nativos; use --backend rustc".into(),
                    );
                }
                for c in field.components {
                    result.components.push(Component {
                        ty: c.ty,
                        offset: offset
                            .checked_add(c.offset)
                            .ok_or("offset fuera de rango")?,
                    });
                }
                result.size = offset
                    .checked_add(field.size)
                    .ok_or("tamaño fuera de rango")?;
            }
            result.size = round(result.size, result.align)?;
            if result.size > i32::MAX as u32 {
                return Err("layout excede el rango de offsets nativos".into());
            }
            struct_active[id] = false;
            struct_cache[id] = Some(result.clone());
            Ok(result)
        }

        #[allow(clippy::too_many_arguments)]
        fn resolve_enum(
            id: usize,
            struct_defs: &[StructDef],
            enum_defs: &[EnumDef],
            array_defs: &[ArrayDef],
            struct_cache: &mut [Option<Layout>],
            struct_active: &mut [bool],
            enum_cache: &mut [Option<EnumLayout>],
            enum_active: &mut [bool],
        ) -> Result<EnumLayout, String> {
            if id >= enum_defs.len() {
                return Err("enum inexistente en layout".into());
            }
            if let Some(layout) = &enum_cache[id] {
                return Ok(layout.clone());
            }
            if std::mem::replace(&mut enum_active[id], true) {
                return Err("enum recursivo por valor".into());
            }
            let mut variants = Vec::new();
            let mut max_variant_align = 8u32; // Discriminant is i64 (align 8)
            let mut max_variant_size = 8u32; // At least 8 bytes for discriminant

            for (_, payload) in &enum_defs[id].variants {
                let mut var_fields = Vec::new();
                let mut cur_offset = 8u32; // starts after the 8-byte discriminant
                let mut var_align = 8u32;

                for ty in payload {
                    let field = resolve_type(
                        *ty,
                        struct_defs,
                        enum_defs,
                        array_defs,
                        struct_cache,
                        struct_active,
                        enum_cache,
                        enum_active,
                    )?;
                    var_align = var_align.max(field.align);
                    let field_offset = round(cur_offset, field.align)?;
                    var_fields.push(field_offset);
                    cur_offset = field_offset
                        .checked_add(field.size)
                        .ok_or("tamaño de variante fuera de rango")?;
                }
                let var_size = round(cur_offset, var_align)?;
                max_variant_align = max_variant_align.max(var_align);
                max_variant_size = max_variant_size.max(var_size);
                variants.push(VariantLayout {
                    fields: var_fields,
                    size: var_size,
                    align: var_align,
                });
            }

            let enum_align = max_variant_align;
            let enum_size = round(max_variant_size, enum_align)?;
            let num_words = enum_size / 8;
            let components = (0..num_words)
                .map(|i| Component {
                    ty: Type::Int,
                    offset: i * 8,
                })
                .collect();

            let enum_layout = EnumLayout {
                layout: Layout {
                    size: enum_size,
                    align: enum_align,
                    fields: Vec::new(),
                    components,
                },
                variants,
            };
            enum_active[id] = false;
            enum_cache[id] = Some(enum_layout.clone());
            Ok(enum_layout)
        }

        let mut structs = Vec::new();
        for id in 0..struct_defs.len() {
            structs.push(resolve_struct(
                id,
                struct_defs,
                enum_defs,
                array_defs,
                &mut struct_cache,
                &mut struct_active,
                &mut enum_cache,
                &mut enum_active,
            )?);
        }
        let mut enums = Vec::new();
        for id in 0..enum_defs.len() {
            enums.push(resolve_enum(
                id,
                struct_defs,
                enum_defs,
                array_defs,
                &mut struct_cache,
                &mut struct_active,
                &mut enum_cache,
                &mut enum_active,
            )?);
        }

        let mut arrays = Vec::new();
        for def in array_defs {
            let elem = resolve_type(
                def.elem,
                struct_defs,
                enum_defs,
                array_defs,
                &mut struct_cache,
                &mut struct_active,
                &mut enum_cache,
                &mut enum_active,
            )?;
            arrays.push(array_layout(&elem, def.len)?);
        }

        Ok(Self {
            structs,
            enums,
            arrays,
        })
    }

    fn primitive(ty: Type) -> Result<Layout, String> {
        let (size, align, components) = match ty {
            Type::Unit => (0, 1, Vec::new()),
            Type::Bool => (1, 1, vec![Component { ty, offset: 0 }]),
            Type::F32 => (4, 4, vec![Component { ty, offset: 0 }]),
            Type::Int | Type::Float => (8, 8, vec![Component { ty, offset: 0 }]),
            Type::SharedField(_) | Type::MutField(_) => (
                8,
                8,
                vec![Component {
                    ty: Type::Int,
                    offset: 0,
                }],
            ),
            Type::Text => (
                24,
                8,
                (0..3)
                    .map(|i| Component {
                        ty: Type::Int,
                        offset: i * 8,
                    })
                    .collect(),
            ),
            // A future is a pointer to its task state, on the heap for as
            // long as the handle lives (so suspended state never moves).
            // A future handle and a task handle are both one pointer: to the
            // task state and to the scheduler's task record respectively.
            Type::Future(_) | Type::Task(_) => (
                8,
                8,
                vec![Component {
                    ty: Type::Int,
                    offset: 0,
                }],
            ),
            // A region is a pointer to its header (in the opening frame).
            Type::Region(_) => (
                8,
                8,
                vec![Component {
                    ty: Type::Int,
                    offset: 0,
                }],
            ),
            // A list or task group owns a heap buffer: (pointer, length, capacity).
            Type::List(_) | Type::RegionList(..) | Type::TaskGroup(_) => {
                let words = if matches!(ty, Type::RegionList(..)) {
                    4
                } else {
                    3
                };
                (
                    words * 8,
                    8,
                    (0..words)
                        .map(|i| Component {
                            ty: Type::Int,
                            offset: i * 8,
                        })
                        .collect(),
                )
            }
            // A region buffer and a slice are views: (pointer, length).
            Type::Bytes(_) | Type::Slice(_) => (
                16,
                8,
                (0..2)
                    .map(|i| Component {
                        ty: Type::Int,
                        offset: i * 8,
                    })
                    .collect(),
            ),
            _ => return Err(format!("tipo no primitivo en layout: {ty:?}")),
        };
        Ok(Layout {
            size,
            align,
            fields: Vec::new(),
            components,
        })
    }

    pub fn get(&self, ty: Type) -> Result<Layout, String> {
        match ty {
            Type::Struct(s) => self
                .structs
                .get(s)
                .cloned()
                .ok_or_else(|| "struct inexistente".into()),
            Type::Enum(e) => self
                .enums
                .get(e)
                .map(|el| el.layout.clone())
                .ok_or_else(|| "enum inexistente".into()),
            Type::Array(a) => self
                .arrays
                .get(a)
                .cloned()
                .ok_or_else(|| "array inexistente".into()),
            _ => Self::primitive(ty),
        }
    }

    pub fn enum_layout(&self, e: usize) -> Result<&EnumLayout, String> {
        self.enums.get(e).ok_or_else(|| "enum inexistente".into())
    }

    pub fn variant_field_offset(
        &self,
        e: usize,
        variant: usize,
        field: usize,
    ) -> Result<u32, String> {
        let el = self.enum_layout(e)?;
        let vl = el
            .variants
            .get(variant)
            .ok_or_else(|| "variante inexistente".to_string())?;
        vl.fields
            .get(field)
            .copied()
            .ok_or_else(|| "campo de variante inexistente".to_string())
    }
}
