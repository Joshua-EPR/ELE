//! Cranelift side of the small Win64 platform ABI.
use super::{Arg, Diagnostic, FnGen, Gen, Helpers, Linkage, flags};
use crate::lir::PlatformOp;
use cranelift_codegen::ir::{
    self, InstBuilder,
    condcodes::IntCC,
    types::{I32, I64},
};
use cranelift_frontend::FunctionBuilder;
use cranelift_module::FuncId;

pub(crate) struct Platform {
    arg_count: FuncId,
    arg: FuncId,
    read_text: FuncId,
    write_bytes: FuncId,
    same_file: FuncId,
    pub(crate) file_stat: FuncId,
    trace: bool,
}

impl Platform {
    pub(crate) fn declare(g: &mut Gen, trace: bool) -> Result<Self, Diagnostic> {
        Ok(Self {
            arg_count: g.declare("l_platform_arg_count", Linkage::Import, &[], &[I64])?,
            arg: g.declare("l_platform_arg", Linkage::Import, &[I64; 2], &[I64])?,
            read_text: g.declare("l_platform_read_text", Linkage::Import, &[I64; 5], &[I64])?,
            write_bytes: g.declare("l_platform_write_bytes", Linkage::Import, &[I64; 4], &[I64])?,
            same_file: g.declare("l_platform_same_file", Linkage::Import, &[I64; 4], &[I64])?,
            file_stat: g.declare("l_platform_file_stat", Linkage::Import, &[I64], &[I64])?,
            trace,
        })
    }
}

impl FnGen<'_> {
    pub(super) fn platform(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        op: PlatformOp,
        args: &[Arg],
    ) -> Result<Vec<ir::Value>, Diagnostic> {
        if op == PlatformOp::PrintError {
            let text = self.arg_values(b, h, &args[0])?;
            let stderr = b.ins().iconst(I32, super::runtime::STDERR);
            h.call(b, self.rt.write, &[stderr, text[0], text[1]]);
            let (newline, len) = h.text(b, "\n")?;
            h.call(b, self.rt.write, &[stderr, newline, len]);
            return Ok(Vec::new());
        }
        let platform = self
            .rt
            .platform
            .as_ref()
            .expect("platform imports declared");
        match op {
            PlatformOp::PrintError => unreachable!(),
            PlatformOp::WriteBytes => {
                // Stage 1 has verified that this borrowed List contains Int.
                // List layout: pointer, length, capacity, region. Each element
                // occupies one signed 64-bit slot. The Win64 primitive validates
                // every byte before opening the destination file.
                let path = self.arg_values(b, h, &args[0])?;
                let bytes = self.arg_values(b, h, &args[1])?;
                let result = h.call(
                    b,
                    platform.write_bytes,
                    &[path[0], path[1], bytes[0], bytes[1]],
                );
                Ok(result)
            }
            PlatformOp::SameFile => {
                let path_a = self.arg_values(b, h, &args[0])?;
                let path_b = self.arg_values(b, h, &args[1])?;
                let result = h.call(
                    b,
                    platform.same_file,
                    &[path_a[0], path_a[1], path_b[0], path_b[1]],
                );
                Ok(result)
            }
            PlatformOp::ArgCount => Ok(h.call(b, platform.arg_count, &[])),
            PlatformOp::Arg | PlatformOp::ReadText => {
                let slot = b.create_sized_stack_slot(ir::StackSlotData::new(
                    ir::StackSlotKind::ExplicitSlot,
                    24,
                    3,
                ));
                let output = b.ins().stack_addr(I64, slot, 0);
                let zero = b.ins().iconst(I64, 0);
                for at in [0, 8, 16] {
                    b.ins().store(flags(), zero, output, at);
                }
                let first = self.arg_values(b, h, &args[0])?;
                let status = if op == PlatformOp::Arg {
                    h.call(b, platform.arg, &[first[0], output])[0]
                } else {
                    let limit = self.arg_values(b, h, &args[1])?[0];
                    let trace = b.ins().iconst(I64, i64::from(platform.trace));
                    h.call(
                        b,
                        platform.read_text,
                        &[first[0], first[1], limit, output, trace],
                    )[0]
                };
                // Result<Text, Int> has tags Ok=0, Err=1 and a payload at
                // offset 8. On failure the out buffer is still all zeros.
                let is_err = b.ins().icmp_imm_s(IntCC::NotEqual, status, 0);
                let tag = b.ins().uextend(I64, is_err);
                let data = b.ins().load(I64, flags(), output, 0);
                let payload = b.ins().select(is_err, status, data);
                let len = b.ins().load(I64, flags(), output, 8);
                let capacity = b.ins().load(I64, flags(), output, 16);
                Ok(vec![tag, payload, len, capacity])
            }
        }
    }
}
