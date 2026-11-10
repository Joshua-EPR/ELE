#!/usr/bin/env python3
"""Compile an ELE .l source through an EXISTING Stage 1 executable, without Rust.

NOTE: Stage 1 currently must be built with Stage 0 (Rust) at least once;
this wrapper does not constitute self-hosting. It only substitutes the backend
and makes repeat source -> LIR -> native builds Rust-free for supported code.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

from ele_c_backend import LirError, compile_lir


def main() -> int:
    p=argparse.ArgumentParser(description="Compile ELE using prebuilt Stage 1 and Rust-free C backend")
    p.add_argument("source",type=Path,help="ELE source .l")
    p.add_argument("--stage1",type=Path,required=True,help="prebuilt sema-l Stage 1 executable")
    p.add_argument("-o","--output",type=Path,required=True,help="output executable")
    p.add_argument("--cc",help="Clang/GCC path (default: cc)")
    p.add_argument("--keep-lir",type=Path,help="write Stage 1 LIR output to this path")
    p.add_argument("--emit-c",type=Path,help="also save standalone generated C11 source")
    args=p.parse_args()
    if args.source.suffix != ".l":
        p.error("ELE source file must have extension .l")
    try:
        result=subprocess.run([str(args.stage1.resolve()),str(args.source.resolve()),"--emit-lir"],
                              capture_output=True,check=False)
        if result.stderr:
            sys.stderr.buffer.write(result.stderr)
        if result.returncode:
            print(f"ELE Stage 1 failed with exit code {result.returncode}",file=sys.stderr)
            return result.returncode if 0 < result.returncode < 256 else 1
        lir=result.stdout.decode("utf-8",errors="strict")
        if not lir.startswith("ELE-LIR 1\n"):
            print("ELE Stage 1 output does not begin with ELE-LIR 1",file=sys.stderr)
            return 1
        with tempfile.TemporaryDirectory(prefix="ele_rustfree_") as tmp:
            lir_file=Path(tmp)/"program.lir"
            lir_file.write_text(lir,encoding="utf-8")
            compile_lir(lir_file,args.output,args.cc,args.emit_c,False)
        if args.keep_lir:
            args.keep_lir.parent.mkdir(parents=True,exist_ok=True)
            args.keep_lir.write_text(lir,encoding="utf-8")
        return 0
    except (OSError,UnicodeError,LirError,subprocess.CalledProcessError,RuntimeError) as e:
        print(f"ELE build failed: {e}",file=sys.stderr)
        return 1


if __name__=="__main__":
    sys.exit(main())
