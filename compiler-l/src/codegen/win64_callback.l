take x86_64

// Static callback entries for Win64 APIs whose arguments and result are
// pointer-sized integer words. The target is an ELE-internal function: its
// parameters arrive on the stack at RBP+16 and it returns one word in RAX.
// The target must not retain borrowed callback arguments after returning.
// No closure environment or exception translation is provided here.
//
// Win64 enters with RSP = 8 (mod 16). RDI and RSI are nonvolatile to the OS
// but scratch registers to ELE, so both are saved and restored. RBP is saved
// by x64FrameBegin/End. RBX and R12-R15 are never touched by the adapter.
// The internal target may call OS functions only through wrappers that align
// their own stacks, as win64_rt and win64_rt_platform already do.

expose flow w64EmitCallback1(code: edit X64Code, target: Int) => Int {
    when target < 0 || target >= code.bytes.length { code.error = 4; give -1 }
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 0)
    x64PushReg(edit code, 7) // RDI
    x64PushReg(edit code, 6) // RSI
    x64PushReg(edit code, 1) // RCX: first argument
    hold call_at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, call_at, target)
    x64LoadMem64(edit code, 6, 5, -16)
    x64LoadMem64(edit code, 7, 5, -8)
    x64FrameEnd(edit code)
    give entry
}

// Four-word entry suitable for the register portion of WndProc's Win64 ABI.
// This is only a trampoline; registration and WndProc lifetime rules must be
// enforced by the eventual public FFI/window API.
expose flow w64EmitCallback4(code: edit X64Code, target: Int) => Int {
    when target < 0 || target >= code.bytes.length { code.error = 4; give -1 }
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 0)
    x64PushReg(edit code, 7) // RDI
    x64PushReg(edit code, 6) // RSI
    x64PushReg(edit code, 9) // R9: fourth argument
    x64PushReg(edit code, 8) // R8: third argument
    x64PushReg(edit code, 2) // RDX: second argument
    x64PushReg(edit code, 1) // RCX: first argument
    hold call_at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, call_at, target)
    x64LoadMem64(edit code, 6, 5, -16)
    x64LoadMem64(edit code, 7, 5, -8)
    x64FrameEnd(edit code)
    give entry
}
